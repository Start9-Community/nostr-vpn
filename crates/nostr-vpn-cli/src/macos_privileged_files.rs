//! Publication of root-owned launchd artifacts. Never clone source metadata.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Component, Path, PathBuf};

use anyhow::{Context, Result, bail};

pub(crate) fn helper_destination(path: &Path) -> Option<PathBuf> {
    let helpers = Path::new("/Library/PrivilegedHelperTools");
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir().ok()?.join(path)
    };
    // Replace a leaf symlink in the actual helper directory, never its target.
    if absolute.starts_with(helpers) {
        return Some(absolute);
    }
    let resolved = fs::canonicalize(&absolute)
        .or_else(|_| {
            let parent = fs::canonicalize(absolute.parent().unwrap_or(Path::new("/")))?;
            Ok::<_, io::Error>(parent.join(absolute.file_name().unwrap_or_default()))
        })
        .ok()?;
    if resolved.starts_with(helpers) {
        return Some(resolved);
    }
    // APFS firmlinks (including the Data volume path) are directory aliases
    // that canonicalize() does not necessarily translate to /Library.
    let helper_metadata = fs::metadata(helpers).ok()?;
    let aliases_helpers = resolved.parent()?.ancestors().any(|parent| {
        fs::metadata(parent).is_ok_and(|metadata| {
            metadata.dev() == helper_metadata.dev() && metadata.ino() == helper_metadata.ino()
        })
    });
    aliases_helpers.then_some(resolved)
}

pub(crate) fn validate_artifact(path: &Path) -> Result<()> {
    protected_directory(
        path.parent().context("system artifact has no parent")?,
        false,
    )?;
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file()
        || metadata.uid() != 0
        || metadata.gid() != 0
        || metadata.mode() & 0o022 != 0
        || metadata.nlink() != 1
    {
        bail!("unsafe system artifact; reinstall the service with administrator privileges");
    }
    reject_write_acl(&file)
}

pub(crate) fn require_root() -> Result<()> {
    if unsafe { libc::geteuid() } != 0 {
        bail!("installing or updating a system helper requires administrator privileges");
    }
    Ok(())
}

/// Validate from the filesystem root down. Once each ancestor is protected,
/// an unprivileged process cannot exchange the next component between checks.
pub(crate) fn protected_directory(path: &Path, create: bool) -> Result<File> {
    if !path.is_absolute() {
        bail!("system artifact directory must be absolute");
    }
    let mut current = PathBuf::new();
    let mut directory = None;
    for component in path.components() {
        match component {
            Component::RootDir | Component::Normal(_) => current.push(component.as_os_str()),
            _ => bail!("system artifact directory must not contain parent traversal"),
        }
        let open = || {
            OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NOFOLLOW | libc::O_DIRECTORY)
                .open(&current)
        };
        let file = match open() {
            Err(error) if create && error.kind() == io::ErrorKind::NotFound => {
                match fs::DirBuilder::new().mode(0o755).create(&current) {
                    Ok(()) => {}
                    Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
                    Err(error) => return Err(error).context("create system artifact directory"),
                }
                open()?
            }
            result => result.with_context(|| format!("open protected {}", current.display()))?,
        };
        let metadata = file.metadata()?;
        if metadata.uid() != 0 || metadata.mode() & 0o022 != 0 {
            bail!(
                "system artifact directory is not root-owned and protected: {}",
                current.display()
            );
        }
        reject_write_acl(&file)?;
        directory = Some(file);
    }
    directory.context("missing system artifact directory")
}

pub(crate) fn install_executable(source: &Path, destination: &Path) -> Result<()> {
    require_root()?;
    let mut source = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(source)
        .context("open service executable")?;
    if !source.metadata()?.is_file() {
        bail!("service executable must be a regular file");
    }
    // Also recopy when source == destination: old installs may have unsafe
    // ownership, ACLs, or open writable descriptors held by their former owner.
    publish(&mut source, destination, 0o755)
}

pub(crate) fn publish(contents: &mut impl Read, destination: &Path, mode: u32) -> Result<()> {
    require_root()?;
    let parent = destination
        .parent()
        .context("system artifact has no parent")?;
    let directory = protected_directory(parent, true)?;
    let name = destination
        .file_name()
        .context("system artifact has no filename")?;
    let mut temporary = None;
    for _ in 0..128 {
        let candidate = parent.join(format!(
            ".{}.{}",
            name.to_string_lossy(),
            rand::random::<u128>()
        ));
        match OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&candidate)
        {
            Ok(file) => {
                temporary = Some((candidate, file));
                break;
            }
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error).context("create system artifact staging file"),
        }
    }
    let (temporary, mut file) = temporary.context("allocate system artifact staging file")?;
    let result = (|| -> Result<()> {
        // Copy bytes into our newly created inode; fs::copy on macOS can clone
        // the installing user's ownership and ACLs from the app bundle.
        io::copy(contents, &mut file)?;
        std::os::unix::fs::fchown(&file, Some(0), Some(0))?;
        file.set_permissions(fs::Permissions::from_mode(mode))?;
        reject_write_acl(&file)?;
        file.sync_all()?;
        // Replaces an old inode or symlink without opening/chmod'ing its target.
        fs::rename(&temporary, destination)?;
        directory.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result.context("publish protected system artifact")
}

// Darwin ACLs can grant writes even when Unix mode bits appear protected.
// Deny and read-only entries are fine; reject every write grant, including
// inherited grants. This deliberately fails closed for unusual system ACLs.
fn reject_write_acl(file: &File) -> Result<()> {
    use std::ffi::c_void;
    unsafe extern "C" {
        fn acl_get_fd_np(fd: i32, kind: u32) -> *mut c_void;
        fn acl_get_entry(acl: *mut c_void, which: i32, entry: *mut *mut c_void) -> i32;
        fn acl_get_tag_type(entry: *mut c_void, tag: *mut u32) -> i32;
        fn acl_get_permset_mask_np(entry: *mut c_void, mask: *mut u64) -> i32;
        fn acl_free(acl: *mut c_void) -> i32;
    }
    const ACL_TYPE_EXTENDED: u32 = 0x100;
    const ACL_EXTENDED_ALLOW: u32 = 1;
    const WRITE_PERMISSIONS: u64 =
        (1 << 2) | (1 << 4) | (1 << 5) | (1 << 6) | (1 << 8) | (1 << 10) | (1 << 12) | (1 << 13);
    let acl = unsafe { acl_get_fd_np(file.as_raw_fd(), ACL_TYPE_EXTENDED) };
    if acl.is_null() {
        let error = io::Error::last_os_error();
        // On a valid descriptor Darwin's FILESEC_ACL lookup returns ENOENT
        // when the inode has no extended ACL (acl_file.c / filesec.c).
        if error.raw_os_error() == Some(libc::ENOENT) {
            return Ok(());
        }
        return Err(error).context("read system artifact ACL");
    }
    let result = (|| -> Result<()> {
        let mut which = 0; // ACL_FIRST_ENTRY
        loop {
            let mut entry = std::ptr::null_mut();
            if unsafe { acl_get_entry(acl, which, &mut entry) } != 0 {
                // Darwin uses EINVAL to indicate the end of this valid ACL.
                if io::Error::last_os_error().raw_os_error() == Some(libc::EINVAL) {
                    break;
                }
                return Err(io::Error::last_os_error()).context("read ACL entry");
            }
            which = -1; // ACL_NEXT_ENTRY
            let mut tag = 0;
            let mut permissions = 0;
            if unsafe { acl_get_tag_type(entry, &mut tag) } != 0
                || unsafe { acl_get_permset_mask_np(entry, &mut permissions) } != 0
            {
                return Err(io::Error::last_os_error()).context("read ACL permissions");
            }
            if tag == ACL_EXTENDED_ALLOW && permissions & WRITE_PERMISSIONS != 0 {
                bail!("system artifact path has a write-granting ACL");
            }
        }
        Ok(())
    })();
    unsafe { acl_free(acl) };
    result
}
