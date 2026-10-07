#[cfg(any(target_os = "macos", test))]
fn remove_obsolete_macos_endpoint_bypasses<Remove>(
    current_routes: &mut Vec<String>,
    current_underlay: &mut Option<crate::MacosRouteSpec>,
    desired_routes: &[String],
    desired_underlay: Option<&crate::MacosRouteSpec>,
    mut remove: Remove,
) -> Result<()>
where
    Remove: FnMut(&str, Option<&crate::MacosRouteSpec>) -> Result<()>,
{
    let underlay_changed = current_underlay.as_ref() != desired_underlay;
    let mut failures = Vec::new();
    for route in current_routes
        .iter()
        .filter(|route| underlay_changed || !desired_routes.contains(route))
    {
        if let Err(error) = remove(route, current_underlay.as_ref()) {
            failures.push(format!("remove endpoint bypass route {route}: {error:#}"));
        }
    }
    // Retain the old ownership until every obsolete route is confirmed gone.
    if !failures.is_empty() {
        return Err(anyhow!(failures.join("; ")));
    }
    if underlay_changed {
        current_routes.clear();
        *current_underlay = None;
    } else {
        current_routes.retain(|route| desired_routes.contains(route));
    }
    Ok(())
}

#[cfg(any(target_os = "macos", test))]
fn apply_macos_endpoint_bypass_route_changes<Apply>(
    current_routes: &mut Vec<String>,
    current_underlay: &mut Option<crate::MacosRouteSpec>,
    desired_routes: &[String],
    desired_underlay: Option<&crate::MacosRouteSpec>,
    force_reapply: bool,
    mut apply: Apply,
) -> Vec<(String, anyhow::Error)>
where
    Apply: FnMut(&str, Option<&str>) -> Result<()>,
{
    let underlay_changed = current_underlay.as_ref() != desired_underlay;
    let mut failures = Vec::new();
    if underlay_changed || force_reapply {
        current_routes.clear();
    } else {
        current_routes.retain(|route| desired_routes.contains(route));
    }
    if let Some(underlay) = desired_underlay {
        let missing = desired_routes
            .iter()
            .filter(|route| underlay_changed || force_reapply || !current_routes.contains(*route))
            .cloned()
            .collect::<Vec<_>>();
        for route in missing {
            if let Err(error) = apply(&route, underlay.gateway.as_deref()) {
                failures.push((route, error));
            } else {
                current_routes.push(route);
            }
        }
    }

    current_routes.sort();
    current_routes.dedup();
    // Only verified installs enter current_routes. Keep the selected underlay
    // cached even when every peer is on-link and no host route is needed.
    // Failed installs still trigger reconciliation through the missing routes.
    *current_underlay = desired_underlay.cloned();
    failures
}
