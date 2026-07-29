#[cfg(test)]
mod tests {
    use super::*;

    include!("tests_windows_route_ownership.rs");
    include!("tests_windows_route_parsing.rs");
    #[cfg(target_os = "macos")]
    include!("tests_macos_route_ownership.rs");
}
