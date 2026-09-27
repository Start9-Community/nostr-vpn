//! Filesystem regression tests: never touch an installed helper or launchd.
#![cfg(target_os = "macos")]

#[path = "../src/macos_privileged_files.rs"]
mod macos_privileged_files;

use macos_privileged_files::*;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, PermissionsExt, chown, symlink};
use std::path::{Path, PathBuf};

struct Fixture(PathBuf);
impl Fixture {
    fn root() -> Self {
        require_root().expect("run this fixture as root explicitly");
        // Publicly traversable ancestors let the dropped-privilege check prove
        // protection of the artifact and its immediate parent, not root's home.
        let path = Path::new("/private/var").join(format!(
            "nvpn-helper-fixture-{:032x}",
            rand::random::<u128>()
        ));
        fs::create_dir(&path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
        Self(path)
    }
    fn path(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}

fn assert_protected(path: &Path, mode: u32) {
    let metadata = fs::symlink_metadata(path).unwrap();
    assert!(metadata.is_file());
    assert_eq!((metadata.uid(), metadata.gid()), (0, 0));
    assert_eq!(metadata.mode() & 0o7777, mode);
    assert_eq!(metadata.nlink(), 1);
    validate_artifact(path).unwrap();
}

#[test]
fn non_root_install_is_rejected_without_writes() {
    if unsafe { libc::geteuid() } == 0 {
        return;
    }
    let path =
        std::env::temp_dir().join(format!("nvpn-no-install-{:032x}", rand::random::<u128>()));
    assert!(install_executable(Path::new("/usr/bin/true"), &path).is_err());
    assert!(publish(&mut &b"plist"[..], &path, 0o644).is_err());
    assert!(!path.exists());
}

#[test]
fn helper_update_paths_are_identified() {
    let helper = Path::new("/Library/PrivilegedHelperTools/to.nostrvpn.nvpn");
    assert_eq!(helper_destination(helper).as_deref(), Some(helper));
    assert!(
        helper_destination(Path::new(
            "/Library/PrivilegedHelperTools/to.nostrvpn.nvpn.instance"
        ))
        .is_some()
    );
    assert!(helper_destination(Path::new("/usr/local/bin/nvpn-fixture-not-installed")).is_none());
    assert!(helper_destination(Path::new("/Library/PrivilegedHelperTools-other/nvpn")).is_none());
    // Read-only check of the OS's directory alias, with no helper file access.
    let data_helpers = Path::new("/System/Volumes/Data/Library/PrivilegedHelperTools");
    if data_helpers.is_dir() {
        assert!(helper_destination(&data_helpers.join("nvpn-fixture-not-installed")).is_some());
    }
}

#[test]
fn protected_directory_rejects_untrusted_ancestors_and_traversal() {
    assert!(protected_directory(Path::new("relative"), false).is_err());
    assert!(protected_directory(Path::new("/private/var/../var"), false).is_err());
    // Even a root-owned child in a writable ancestor is not a trusted path.
    assert!(protected_directory(Path::new("/private/tmp"), false).is_err());
    assert!(protected_directory(Path::new("/tmp"), false).is_err());
    protected_directory(Path::new("/"), false).unwrap();
}

#[test]
#[ignore = "requires root; only creates isolated filesystem fixtures"]
fn root_install_replacement_and_same_path_repair() {
    let fixture = Fixture::root();
    let source = fixture.path("app-nvpn");
    let destination = fixture.path("helpers/nvpn");
    fs::write(&source, b"first inert fixture").unwrap();
    chown(&source, Some(65534), Some(65534)).unwrap();
    fs::set_permissions(&source, fs::Permissions::from_mode(0o777)).unwrap();

    // Reproduce the old production copy on this filesystem without executing it.
    let legacy = fixture.path("legacy-copy");
    fs::copy(&source, &legacy).unwrap();
    eprintln!(
        "legacy fs::copy retained source owner: {}",
        fs::metadata(&legacy).unwrap().uid() == 65534
    );

    install_executable(&source, &destination).unwrap();
    assert_protected(&destination, 0o755);
    assert_eq!(fs::read(&source).unwrap(), fs::read(&destination).unwrap());
    let mut old_reader = File::open(&destination).unwrap();
    fs::write(&source, b"updated inert fixture").unwrap();
    install_executable(&source, &destination).unwrap();
    let mut old_bytes = Vec::new();
    old_reader.read_to_end(&mut old_bytes).unwrap();
    assert_eq!(old_bytes, b"first inert fixture");
    assert_eq!(fs::read(&destination).unwrap(), b"updated inert fixture");
    assert_protected(&destination, 0o755);

    chown(&destination, Some(65534), Some(65534)).unwrap();
    let mut former_owner_handle = OpenOptions::new().write(true).open(&destination).unwrap();
    assert!(validate_artifact(&destination).is_err());
    install_executable(&destination, &destination).unwrap();
    assert_protected(&destination, 0o755);
    former_owner_handle.write_all(b"stale descriptor").unwrap();
    assert_eq!(fs::read(&destination).unwrap(), b"updated inert fixture");
    let plist = fixture.path("daemons/service.plist");
    publish(&mut &b"plist fixture"[..], &plist, 0o644).unwrap();
    assert_protected(&plist, 0o644);

    use std::os::unix::ffi::OsStrExt;
    let destination_c = std::ffi::CString::new(destination.as_os_str().as_bytes()).unwrap();
    let replacement_c = std::ffi::CString::new(source.as_os_str().as_bytes()).unwrap();
    // Only async-signal-safe syscalls in the child of this multithreaded runner.
    let child = unsafe { libc::fork() };
    assert!(child >= 0);
    if child == 0 {
        unsafe {
            if libc::setgroups(0, std::ptr::null()) != 0
                || libc::setgid(65534) != 0
                || libc::setuid(65534) != 0
            {
                libc::_exit(2);
            }
            if libc::open(destination_c.as_ptr(), libc::O_WRONLY) >= 0 {
                libc::_exit(3);
            }
            if libc::rename(replacement_c.as_ptr(), destination_c.as_ptr()) == 0 {
                libc::_exit(4);
            }
            libc::_exit(0);
        }
    }
    let mut status = 0;
    assert_eq!(unsafe { libc::waitpid(child, &mut status, 0) }, child);
    assert_eq!(
        status, 0,
        "unprivileged write/replace attempt must be denied"
    );
    assert_eq!(fs::read(&destination).unwrap(), b"updated inert fixture");
}

#[test]
#[ignore = "requires root; only creates isolated filesystem fixtures"]
fn root_install_does_not_follow_links_or_accept_unsafe_parents() {
    let fixture = Fixture::root();
    let source = fixture.path("source");
    let victim = fixture.path("victim");
    let destination = fixture.path("installed");
    fs::write(&source, b"new fixture").unwrap();
    fs::write(&victim, b"preserved fixture").unwrap();
    fs::set_permissions(&victim, fs::Permissions::from_mode(0o600)).unwrap();
    for hard_link in [false, true] {
        if hard_link {
            fs::hard_link(&victim, &destination).unwrap();
        } else {
            symlink(&victim, &destination).unwrap();
        }
        install_executable(&source, &destination).unwrap();
        assert_eq!(fs::read(&victim).unwrap(), b"preserved fixture");
        assert_eq!(fs::metadata(&victim).unwrap().mode() & 0o777, 0o600);
        assert_protected(&destination, 0o755);
        fs::remove_file(&destination).unwrap();
    }
    let linked_source = fixture.path("source-link");
    symlink(&source, &linked_source).unwrap();
    assert!(install_executable(&linked_source, &destination).is_err());
    assert!(install_executable(&fixture.0, &destination).is_err());
    let parent = fixture.path("parent");
    fs::create_dir(&parent).unwrap();
    let parent_link = fixture.path("parent-link");
    symlink(&parent, &parent_link).unwrap();
    assert!(install_executable(&source, &parent_link.join("nvpn")).is_err());
    fs::set_permissions(&parent, fs::Permissions::from_mode(0o777)).unwrap();
    assert!(install_executable(&source, &parent.join("nvpn")).is_err());
    fs::set_permissions(&parent, fs::Permissions::from_mode(0o755)).unwrap();
    chown(&parent, Some(65534), None).unwrap();
    assert!(install_executable(&source, &parent.join("nvpn")).is_err());
    assert!(!parent.join("nvpn").exists());
}

#[test]
#[ignore = "requires root; only creates isolated filesystem fixtures"]
fn root_install_rejects_write_acls_and_does_not_copy_source_acl() {
    let fixture = Fixture::root();
    let source = fixture.path("source");
    let destination = fixture.path("installed");
    fs::write(&source, b"inert fixture").unwrap();
    let status = std::process::Command::new("/bin/chmod")
        .args(["+a", "everyone allow write,append,writeattr,writeextattr"])
        .arg(&source)
        .status()
        .unwrap();
    assert!(status.success());
    install_executable(&source, &destination).unwrap();
    assert_protected(&destination, 0o755);
    let parent = fixture.path("parent");
    fs::create_dir(&parent).unwrap();
    let status = std::process::Command::new("/bin/chmod")
        .args([
            "+a",
            "everyone allow add_file,add_subdirectory,delete_child",
        ])
        .arg(&parent)
        .status()
        .unwrap();
    assert!(status.success());
    assert!(install_executable(&source, &parent.join("nvpn")).is_err());
    assert!(!parent.join("nvpn").exists());
}

#[test]
#[ignore = "requires root; only creates isolated filesystem fixtures"]
fn root_failed_publication_preserves_existing_artifact() {
    struct FailingReader;
    impl Read for FailingReader {
        fn read(&mut self, _: &mut [u8]) -> std::io::Result<usize> {
            Err(std::io::Error::other("fixture read failure"))
        }
    }
    let fixture = Fixture::root();
    let destination = fixture.path("installed");
    publish(&mut &b"old fixture"[..], &destination, 0o755).unwrap();
    assert!(publish(&mut FailingReader, &destination, 0o755).is_err());
    assert_eq!(fs::read(&destination).unwrap(), b"old fixture");
    assert_eq!(fs::read_dir(&fixture.0).unwrap().count(), 1);
}
