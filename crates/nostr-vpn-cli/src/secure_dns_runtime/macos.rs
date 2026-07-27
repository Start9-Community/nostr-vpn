use std::io::Write as _;
use std::path::{Path, PathBuf};

use super::SECURE_DNS_PORT;

pub(super) fn macos_resolver_configs() -> [(PathBuf, String); 2] {
    [
        (
            PathBuf::from("/etc/resolver/nvpn"),
            macos_magic_dns_resolver_config(),
        ),
        (
            PathBuf::from("/etc/resolver/nvpn-secure-dns"),
            macos_secure_dns_resolver_config(),
        ),
    ]
}

pub(super) fn write_macos_resolver_atomically(path: &Path, contents: &str) -> std::io::Result<()> {
    refuse_foreign_macos_resolver_file(path, contents)?;
    let parent = path.parent().ok_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!("resolver path has no parent: {}", path.display()),
        )
    })?;
    let file_name = path
        .file_name()
        .and_then(std::ffi::OsStr::to_str)
        .ok_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                format!("resolver path has no UTF-8 file name: {}", path.display()),
            )
        })?;
    let temporary = parent.join(format!(".{file_name}.nvpn-{}.tmp", std::process::id()));
    let _ = std::fs::remove_file(&temporary);
    let result = (|| -> std::io::Result<()> {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        file.write_all(contents.as_bytes())?;
        file.sync_all()?;
        std::fs::rename(&temporary, path)?;
        std::fs::File::open(parent)?.sync_all()
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}

pub(super) fn remove_owned_macos_resolver_file(path: &Path) -> std::io::Result<bool> {
    let metadata = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error),
    };
    if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
        return Ok(false);
    }
    let contents = std::fs::read(path)?;
    if !macos_resolver_contents_owned(path, &contents) {
        return Ok(false);
    }
    match std::fs::remove_file(path) {
        Ok(()) => {
            if let Some(parent) = path.parent() {
                std::fs::File::open(parent)?.sync_all()?;
            }
            Ok(true)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
    }
}

pub(crate) fn cleanup_owned_macos_secure_dns_resolver_files() -> anyhow::Result<bool> {
    let mut removed = false;
    let mut failures = Vec::new();
    for path in [
        Path::new("/etc/resolver/nvpn-secure-dns"),
        Path::new("/etc/resolver/nvpn"),
    ] {
        match remove_owned_macos_resolver_file(path) {
            Ok(was_removed) => removed |= was_removed,
            Err(error) => failures.push(format!("remove {}: {error}", path.display())),
        }
    }
    if failures.is_empty() {
        Ok(removed)
    } else {
        Err(anyhow::anyhow!(failures.join("; ")))
    }
}

fn refuse_foreign_macos_resolver_file(path: &Path, expected: &str) -> std::io::Result<()> {
    let metadata = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::AlreadyExists,
            format!(
                "refusing to replace non-regular resolver path {}",
                path.display()
            ),
        ));
    }
    let current = std::fs::read(path)?;
    if current == expected.as_bytes() {
        Ok(())
    } else {
        Err(std::io::Error::new(
            std::io::ErrorKind::AlreadyExists,
            format!(
                "refusing to replace foreign resolver file {}",
                path.display()
            ),
        ))
    }
}

fn macos_resolver_contents_owned(path: &Path, contents: &[u8]) -> bool {
    match path.file_name().and_then(std::ffi::OsStr::to_str) {
        Some("nvpn") => contents == macos_magic_dns_resolver_config().as_bytes(),
        Some("nvpn-secure-dns") => contents == macos_secure_dns_resolver_config().as_bytes(),
        _ => false,
    }
}

pub(super) fn macos_secure_dns_resolver_config() -> String {
    format!(
        "# Managed by nvpn\ndomain .\nsearch_order 1\nnameserver 127.0.0.1\nport {SECURE_DNS_PORT}\noptions timeout:1 attempts:1\n"
    )
}

pub(super) fn macos_magic_dns_resolver_config() -> String {
    format!(
        "# Managed by nvpn secure DNS\nnameserver 127.0.0.1\nport {SECURE_DNS_PORT}\noptions timeout:1 attempts:1\n"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ownership_requires_the_exact_expected_path_and_contents() {
        let magic = macos_magic_dns_resolver_config();
        assert!(macos_resolver_contents_owned(
            Path::new("/etc/resolver/nvpn"),
            magic.as_bytes()
        ));
        assert!(!macos_resolver_contents_owned(
            Path::new("/etc/resolver/nvpn"),
            b"# Managed by nvpn secure DNS\nforeign\n"
        ));
        assert!(!macos_resolver_contents_owned(
            Path::new("/etc/resolver/foreign"),
            magic.as_bytes()
        ));
    }

    #[test]
    fn install_and_cleanup_preserve_foreign_resolver_files() {
        let directory = std::env::temp_dir().join(format!(
            "nvpn-macos-resolver-ownership-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir(&directory).expect("temporary resolver directory");
        let path = directory.join("nvpn");
        std::fs::write(&path, b"nameserver 192.0.2.53\n").expect("foreign resolver");

        let expected = macos_magic_dns_resolver_config();
        let error = write_macos_resolver_atomically(&path, &expected)
            .expect_err("foreign resolver must not be replaced");
        assert_eq!(error.kind(), std::io::ErrorKind::AlreadyExists);
        assert_eq!(
            std::fs::read(&path).expect("preserved foreign resolver"),
            b"nameserver 192.0.2.53\n"
        );
        assert!(!remove_owned_macos_resolver_file(&path).expect("foreign cleanup"));
        assert!(path.exists());

        std::fs::write(&path, expected).expect("owned resolver");
        assert!(remove_owned_macos_resolver_file(&path).expect("owned cleanup"));
        assert!(!path.exists());
        std::fs::remove_dir(directory).expect("remove temporary resolver directory");
    }
}
