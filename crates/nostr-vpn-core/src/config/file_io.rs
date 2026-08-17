const MAX_SHARED_ROSTER_FUTURE_SECS: u64 = 600;

fn next_shared_roster_updated_at(previous: u64) -> u64 {
    current_unix_timestamp().max(previous.saturating_add(1))
}

/// Atomically writes a private file while retaining an existing non-root owner.
pub fn write_private_file_preserving_user_owner(
    path: &Path,
    raw: &[u8],
) -> std::io::Result<()> {
    #[cfg(unix)]
    use std::os::unix::fs::MetadataExt;

    #[cfg(unix)]
    let existing_owner = fs::metadata(path)
        .ok()
        .map(|metadata| (metadata.uid(), metadata.gid()));
    #[cfg(unix)]
    let parent_owner = {
        let parent = path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
            .unwrap_or_else(|| Path::new("."));
        fs::metadata(parent)
            .ok()
            .map(|metadata| (metadata.uid(), metadata.gid()))
    };
    #[cfg(unix)]
    let desired_owner = preferred_private_file_owner(existing_owner, parent_owner);
    #[cfg(not(unix))]
    let desired_owner = None;
    write_private_file_with_owner(path, raw, desired_owner)
}

pub(crate) fn write_private_file_with_owner(
    path: &Path,
    raw: &[u8],
    desired_owner: Option<(u32, u32)>,
) -> std::io::Result<()> {
    #[cfg(unix)]
    use std::os::unix::fs::MetadataExt;
    #[cfg(not(unix))]
    let _ = desired_owner;

    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let file_name = path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("config");
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |duration| duration.as_nanos());
    let mut temp_path = None;
    let mut temp_file = None;
    for attempt in 0..128u32 {
        let candidate = parent.join(format!(
            ".{file_name}.tmp-{}-{nonce}-{attempt}",
            std::process::id()
        ));
        let mut options = OpenOptions::new();
        options.create_new(true).write(true);
        #[cfg(unix)]
        options.mode(0o600);
        match options.open(&candidate) {
            Ok(file) => {
                temp_path = Some(candidate);
                temp_file = Some(file);
                break;
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        }
    }
    let temp_path = temp_path.ok_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::AlreadyExists,
            "failed to allocate unique config temp file",
        )
    })?;
    let mut file = temp_file.expect("temp file set with temp path");
    if let Err(error) = file.write_all(raw) {
        let _ = fs::remove_file(&temp_path);
        return Err(error);
    }
    #[cfg(unix)]
    {
        let secure = (|| {
            if let Some((uid, gid)) = desired_owner {
                let metadata = file.metadata()?;
                if metadata.uid() != uid || metadata.gid() != gid {
                    match std::os::unix::fs::fchown(&file, Some(uid), Some(gid)) {
                        Ok(()) => {}
                        Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied => {}
                        Err(error) => return Err(error),
                    }
                }
            }
            file.set_permissions(fs::Permissions::from_mode(0o600))
        })();
        if let Err(error) = secure {
            drop(file);
            let _ = fs::remove_file(&temp_path);
            return Err(error);
        }
    }
    if let Err(error) = file.sync_all() {
        let _ = fs::remove_file(&temp_path);
        return Err(error);
    }
    drop(file);
    if let Err(error) = replace_private_file(&temp_path, path) {
        let _ = fs::remove_file(&temp_path);
        return Err(error);
    }
    #[cfg(unix)]
    fs::File::open(parent)?.sync_all()?;
    Ok(())
}

#[cfg(not(windows))]
fn replace_private_file(temporary: &Path, destination: &Path) -> std::io::Result<()> {
    fs::rename(temporary, destination)
}

#[cfg(windows)]
fn replace_private_file(temporary: &Path, destination: &Path) -> std::io::Result<()> {
    use std::os::windows::ffi::OsStrExt as _;
    use windows_sys::Win32::Storage::FileSystem::{
        MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH, MoveFileExW,
    };

    let temporary = temporary
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    let destination = destination
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    // SAFETY: both arguments are valid, NUL-terminated UTF-16 paths for this call.
    let moved = unsafe {
        MoveFileExW(
            temporary.as_ptr(),
            destination.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if moved == 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(unix)]
pub(crate) fn preferred_private_file_owner(
    existing_owner: Option<(u32, u32)>,
    parent_owner: Option<(u32, u32)>,
) -> Option<(u32, u32)> {
    match (existing_owner, parent_owner) {
        (Some((0, _)), Some((parent_uid, parent_gid))) if parent_uid != 0 => {
            Some((parent_uid, parent_gid))
        }
        (Some(owner), _) => Some(owner),
        (None, Some((parent_uid, parent_gid))) if parent_uid != 0 => Some((parent_uid, parent_gid)),
        (None, _) => None,
    }
}
