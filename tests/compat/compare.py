#!/usr/bin/python3
"""Report how two images' root filesystems differ, for `just compare`.

Usage (rootless, under `podman unshare`): compare.py REFERENCE SEED

Compares every path's type, mode, ownership, link target, content and file
capabilities and user.* extended attributes, and attributes differences to
the packages owning the path. Not compared: SELinux labels (a mounted image
shows the host's storage labels), hardlinks and the image configuration;
differing mtimes are only counted. Exits with EXIT_PACKAGES_DIFFER if the
package sets or versions differ, as the report would then mostly show that.
"""
import collections
import hashlib
import os
import stat
import subprocess
import sys

# Paths listed per difference before eliding the rest.
MAX_LISTED = 60
# Fields compared for paths present in both images, after the type.
FIELDS = ("target", "mode", "uid", "gid", "sha256", "xattrs")
# SELinux labels aren't image content when mounted from container storage.
XATTR_PREFIXES = ("security.capability", "user.")
# Not real packages: gpg-pubkey entries record the repo keys dnf imported.
PSEUDO_PACKAGES = {"gpg-pubkey"}
# Same limit as the kernel's for following symlinks.
MAX_SYMLINKS = 40
EXIT_PACKAGES_DIFFER = 2


def file_record(path):
    st = os.lstat(path)
    rec = {"mode": stat.S_IMODE(st.st_mode), "uid": st.st_uid, "gid": st.st_gid,
           "mtime": int(st.st_mtime)}
    if stat.S_ISLNK(st.st_mode):
        rec.update(type="l", target=os.readlink(path))
    elif stat.S_ISDIR(st.st_mode):
        rec["type"] = "d"
    elif stat.S_ISREG(st.st_mode):
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        rec.update(type="f", sha256=h.hexdigest())
    else:
        rec["type"] = "other"
    xattrs = {x: os.getxattr(path, x, follow_symlinks=False).hex()
              for x in sorted(os.listxattr(path, follow_symlinks=False))
              if x.startswith(XATTR_PREFIXES)}
    if xattrs:
        rec["xattrs"] = xattrs
    return rec


def tree(root):
    def fail(err):
        raise err

    out = {"/": file_record(root)}
    for dirpath, dirnames, filenames in os.walk(root, onerror=fail):
        for name in dirnames + filenames:
            full = os.path.join(dirpath, name)
            out["/" + os.path.relpath(full, root)] = file_record(full)
    return out


def podman(*args):
    return subprocess.run(["podman", *args], check=True, stdout=subprocess.PIPE, text=True).stdout


def image_tree(image):
    mnt = podman("image", "mount", image).strip()
    try:
        result = tree(mnt)
    except BaseException:
        # Don't let a failing unmount hide the original error; podman reports
        # its own failure on stderr.
        subprocess.run(["podman", "image", "unmount", image], check=False)
        raise
    podman("image", "unmount", image)
    return result


def parse_rpm_query(text):
    """Parse `F path name` and `V name evr` lines into {path: {names}} and
    {name: {evrs}}."""
    owners, versions = collections.defaultdict(set), collections.defaultdict(set)
    for line in text.splitlines():
        kind, a, b = line.split("\t")
        if kind == "F":
            owners[a].add(b)
        elif kind == "V":
            versions[a].add(b)
        else:
            raise ValueError(f"unexpected line: {line!r}")
    return owners, versions


def image_packages(image):
    qf = "[F\\t%{FILENAMES}\\t%{=NAME}\\n]V\\t%{NAME}\\t%{EVR}.%{ARCH}\\n"
    return parse_rpm_query(podman("run", "--rm", image, "rpm", "-qa", "--qf", qf))


def resolve_dirs(path, files, depth=0):
    """`path` with the symlinked directories among its parents resolved in
    `files`, e.g. /lib64/x to /usr/lib64/x: rpm records paths as packaged."""
    if depth > MAX_SYMLINKS:
        raise ValueError(f"too many levels of symbolic links: {path}")
    parts = path.strip("/").split("/")
    for i in range(1, len(parts)):
        parent = "/" + "/".join(parts[:i])
        rec = files.get(parent)
        if rec and rec["type"] == "l":
            base = "/" if rec["target"].startswith("/") else os.path.dirname(parent)
            resolved = os.path.normpath(os.path.join(base, rec["target"], *parts[i:]))
            return resolve_dirs(resolved, files, depth + 1)
    return path


def top_level(paths):
    """The paths whose parent directory is not itself in `paths`, with the
    number of paths below each."""
    paths = set(paths)
    tops = sorted(p for p in paths if os.path.dirname(p) not in paths)
    return [(p, sum(1 for q in paths if q.startswith(p + "/"))) for p in tops]


def compare(ref, seed):
    """Differences between two trees, as {field: [(path, ref, seed)]}."""
    diffs = collections.defaultdict(list)
    for p in sorted(ref.keys() & seed.keys()):
        r, s = ref[p], seed[p]
        if r["type"] != s["type"]:
            diffs["type"].append((p, r["type"], s["type"]))
            continue
        for field in FIELDS:
            if r.get(field) != s.get(field):
                diffs[field].append((p, r.get(field), s.get(field)))
    return diffs


def package_differences(ref_versions, seed_versions):
    only_ref = sorted(ref_versions.keys() - seed_versions.keys())
    only_seed = sorted(seed_versions.keys() - ref_versions.keys())
    changed = sorted(n for n in ref_versions.keys() & seed_versions.keys()
                     if ref_versions[n] != seed_versions[n])
    return only_ref, only_seed, changed


def main(ref_image, seed_image):
    ref_owners, ref_versions = image_packages(ref_image)
    seed_owners, seed_versions = image_packages(seed_image)
    only_ref, only_seed, changed = package_differences(ref_versions, seed_versions)
    print("== Packages")
    print("only in the reference:", " ".join(only_ref) or "none")
    print("only in the seed:", " ".join(only_seed) or "none")
    print("different versions:", " ".join(changed) or "none")
    if changed or (set(only_ref) | set(only_seed)) - PSEUDO_PACKAGES:
        print("error: the images have different packages; rebuild them from the same repos", file=sys.stderr)
        return EXIT_PACKAGES_DIFFER

    ref, seed = image_tree(ref_image), image_tree(seed_image)
    owners = collections.defaultdict(set)
    for pkg_owners, files in ((ref_owners, ref), (seed_owners, seed)):
        for path, names in pkg_owners.items():
            owners[resolve_dirs(path, files)] |= names

    def owner(p):
        return ",".join(sorted(owners.get(p, ()))) or "-"

    for title, a, b in (("only in the reference", ref, seed), ("only in the seed", seed, ref)):
        tops = top_level(a.keys() - b.keys())
        print(f"\n== Paths {title}: {sum(n + 1 for _, n in tops)}")
        for p, below in tops:
            target = f" -> {a[p]['target']}" if a[p]["type"] == "l" else ""
            more = f" (+{below} below)" if below else ""
            print(f"  {a[p]['type']} {p}{target} [{owner(p)}]{more}")

    print("\n== Paths that differ")
    for field, items in compare(ref, seed).items():
        print(f"-- {field}: {len(items)}")
        for p, r, s in items[:MAX_LISTED]:
            if field == "mode":
                r, s = f"{r:04o}", f"{s:04o}"
            values = "" if field == "sha256" else f" reference={r} seed={s}"
            print(f"  {p}{values} [{owner(p)}]")
        if len(items) > MAX_LISTED:
            print(f"  ... and {len(items) - MAX_LISTED} more")
    common = ref.keys() & seed.keys()
    mtimes = sum(1 for p in common if ref[p]["mtime"] != seed[p]["mtime"])
    print(f"\n== mtimes differ for {mtimes} of {len(common)} common paths")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2]))
