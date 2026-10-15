"""Unit tests for compare.py; run with `just test-unit`."""
import unittest

import compare


def d():
    return {"type": "d", "mode": 0o755, "uid": 0, "gid": 0, "mtime": 0}


def f(sha="a", mode=0o644, mtime=0):
    return {"type": "f", "mode": mode, "uid": 0, "gid": 0, "mtime": mtime, "sha256": sha}


def link(target):
    return {"type": "l", "target": target, "mode": 0o777, "uid": 0, "gid": 0, "mtime": 0}


class TestCompare(unittest.TestCase):
    def test_parse_rpm_query(self):
        cases = [
            ("", {}, {}),
            ("F\t/usr/bin/a\tpkg\nV\tpkg\t1.0-1.x86_64",
             {"/usr/bin/a": {"pkg"}}, {"pkg": {"1.0-1.x86_64"}}),
            # A shared directory, and a package installed in two versions.
            ("F\t/usr/lib\tone\nF\t/usr/lib\ttwo\nV\tkernel\t1-1.x86_64\nV\tkernel\t2-1.x86_64",
             {"/usr/lib": {"one", "two"}}, {"kernel": {"1-1.x86_64", "2-1.x86_64"}}),
        ]
        for text, owners, versions in cases:
            with self.subTest(text=text):
                got_owners, got_versions = compare.parse_rpm_query(text)
                self.assertEqual((dict(got_owners), dict(got_versions)), (owners, versions))
        with self.assertRaises(ValueError):
            compare.parse_rpm_query("X\ta\tb")

    def test_resolve_dirs(self):
        files = {"/lib64": link("usr/lib64"), "/usr/lib64": d(), "/abs": link("/usr"),
                 "/usr/lib64/x": f(), "/loop": link("loop")}
        cases = [
            ("/lib64/x", "/usr/lib64/x"),
            ("/abs/lib64/x", "/usr/lib64/x"),
            ("/usr/lib64/x", "/usr/lib64/x"),
            # The last component is the path itself, not a parent to resolve.
            ("/lib64", "/lib64"),
        ]
        for path, want in cases:
            with self.subTest(path=path):
                self.assertEqual(compare.resolve_dirs(path, files), want)
        with self.assertRaises(ValueError):
            compare.resolve_dirs("/loop/x", files)

    def test_top_level(self):
        cases = [
            (set(), []),
            ({"/a", "/a/b", "/a/b/c", "/d"}, [("/a", 2), ("/d", 0)]),
            # /x/y's parent isn't in the set, so it is a top of its own.
            ({"/x/y", "/x/y/z"}, [("/x/y", 1)]),
        ]
        for paths, want in cases:
            with self.subTest(paths=paths):
                self.assertEqual(compare.top_level(paths), want)

    def test_compare(self):
        cases = [
            ({"/a": f()}, {"/a": f()}, {}),
            # Every differing field is reported, not just the first.
            ({"/a": f("x", 0o644)}, {"/a": f("y", 0o600)},
             {"mode": [("/a", 0o644, 0o600)], "sha256": [("/a", "x", "y")]}),
            # After a type mismatch, the other fields are meaningless.
            ({"/a": d()}, {"/a": link("b")}, {"type": [("/a", "d", "l")]}),
            # mtimes are only counted by main(); paths in one tree only are
            # reported separately.
            ({"/a": f(mtime=0), "/b": f()}, {"/a": f(mtime=5)}, {}),
        ]
        for ref, seed, want in cases:
            with self.subTest(ref=ref, seed=seed):
                self.assertEqual(dict(compare.compare(ref, seed)), want)

    def test_package_differences(self):
        cases = [
            ({"a": {"1"}}, {"a": {"1"}}, ([], [], [])),
            ({"a": {"1"}, "b": {"1"}}, {"a": {"2"}, "c": {"1"}}, (["b"], ["c"], ["a"])),
        ]
        for ref, seed, want in cases:
            with self.subTest(ref=ref, seed=seed):
                self.assertEqual(compare.package_differences(ref, seed), want)


if __name__ == "__main__":
    unittest.main()
