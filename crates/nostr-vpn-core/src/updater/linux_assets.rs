// os-release is data, never shell input. ID_LIKE covers distributions derived
// from Debian/Ubuntu or Arch without assuming every Linux host accepts a .deb.
pub(super) fn app_asset_suffixes(os_release: &str, arch: &str) -> Vec<String> {
    let arch = match arch {
        "x86_64" => "x64",
        "aarch64" => "arm64",
        _ => return Vec::new(),
    };
    let mut family = Vec::new();
    for line in os_release.lines() {
        let Some((key, value)) = line.trim().split_once('=') else {
            continue;
        };
        if matches!(key, "ID" | "ID_LIKE") {
            family.extend(
                value
                    .trim()
                    .trim_matches(['\'', '"'])
                    .split_ascii_whitespace(),
            );
        }
    }
    let mut suffixes = vec![format!("-linux-{arch}.appimage")];
    if family.iter().any(|id| matches!(*id, "debian" | "ubuntu")) {
        suffixes.push(format!("-linux-{arch}.deb"));
    } else if family.contains(&"arch") {
        suffixes.push(format!("-linux-{arch}.pkg.tar.zst"));
    }
    suffixes
}

#[cfg(test)]
mod tests {
    use super::*;
    use hashtree_updater::{UpdateAsset, UpdateManifest, preferred_app_asset_for_suffixes};

    #[test]
    fn release_selection_matches_linux_distribution_and_architecture() {
        let manifest = UpdateManifest {
            assets: [
                "NostrVpn-v4.1.19-linux-arm64.deb",
                "NostrVpn-v4.1.19-linux-x64.deb",
                "NostrVpn-v4.1.19-linux-x64.pkg.tar.zst",
                "NostrVpn-v4.1.19-linux-arm64.pkg.tar.zst",
            ]
            .into_iter()
            .map(|name| UpdateAsset {
                name: name.into(),
                ..Default::default()
            })
            .collect(),
            ..Default::default()
        };
        for (release, arch, expected) in [
            ("ID=debian", "x86_64", "-linux-x64.deb"),
            ("ID=ubuntu\nID_LIKE=debian", "aarch64", "-linux-arm64.deb"),
            (
                "ID=linuxmint\nID_LIKE=\"ubuntu debian\"",
                "x86_64",
                "-linux-x64.deb",
            ),
            ("ID=arch", "x86_64", "-linux-x64.pkg.tar.zst"),
            (
                "ID=manjaro\nID_LIKE=arch",
                "aarch64",
                "-linux-arm64.pkg.tar.zst",
            ),
        ] {
            let selected =
                preferred_app_asset_for_suffixes(&manifest, &app_asset_suffixes(release, arch))
                    .unwrap();
            assert!(selected.name.ends_with(expected), "{}", selected.name);
        }
        for release in ["ID=fedora", "", "# ID_LIKE=debian", "ID=archlinuxish"] {
            assert!(
                preferred_app_asset_for_suffixes(&manifest, &app_asset_suffixes(release, "x86_64"))
                    .is_none()
            );
        }
        assert!(app_asset_suffixes("ID=debian", "arm").is_empty());
        let portable = UpdateManifest {
            assets: vec![UpdateAsset {
                name: "NostrVpn-v4.1.19-linux-x64.AppImage".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        assert!(
            preferred_app_asset_for_suffixes(&portable, &app_asset_suffixes("ID=fedora", "x86_64"))
                .is_some()
        );
    }
}
