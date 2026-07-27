#[cfg(any(target_os = "macos", test))]
fn apply_macos_endpoint_bypass_route_changes<Apply>(
    current_routes: &mut Vec<String>,
    current_underlay: &mut Option<crate::MacosRouteSpec>,
    desired_routes: &[String],
    desired_underlay: Option<&crate::MacosRouteSpec>,
    mut apply: Apply,
) -> Vec<(String, anyhow::Error)>
where
    Apply: FnMut(&str, Option<&str>) -> Result<()>,
{
    let underlay_changed = current_underlay.as_ref() != desired_underlay;
    let mut failures = Vec::new();
    if let Some(underlay) = desired_underlay {
        for route in desired_routes
            .iter()
            .filter(|route| underlay_changed || !current_routes.contains(*route))
        {
            if let Err(error) = apply(route, underlay.gateway.as_deref()) {
                failures.push((route.clone(), error));
            }
        }
    }

    current_routes.clear();
    current_routes.extend_from_slice(desired_routes);
    current_routes.sort();
    current_routes.dedup();
    // A failed route add/change must leave the cache invalid. The next peer
    // event then re-enters this production reconciliation path and retries
    // every desired bypass against a freshly resolved physical underlay.
    *current_underlay = if failures.is_empty() {
        desired_underlay.cloned()
    } else {
        None
    };
    failures
}
