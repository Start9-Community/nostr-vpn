use std::cell::Cell;
#[cfg(target_os = "linux")]
use std::cell::RefCell;
use std::collections::{BTreeMap, HashSet};
use std::rc::Rc;
use std::sync::Mutex;

use super::*;

static TEST_LOCK: Mutex<()> = Mutex::new(());

#[derive(Debug, Clone, PartialEq, Eq)]
struct FakeNetworkState {
    link_exists: bool,
    address: Option<String>,
    wireguard_config: String,
    mtu: u64,
    up: bool,
    endpoint_routes: BTreeMap<String, Vec<String>>,
    table_routes: Vec<String>,
    main_routes: Vec<String>,
    policy_rule_present: bool,
}

struct FakeRunner {
    state: FakeNetworkState,
    commands: Vec<(String, Vec<String>)>,
    stdin_commands: Vec<(String, Vec<String>, Vec<u8>)>,
    table_missing_when_empty: bool,
    table_error: Option<String>,
    fail_route_cache_once: bool,
    fail_showconf: bool,
    fail_link_delete: bool,
    fail_restore_endpoint: bool,
    fail_after_mutation: Option<usize>,
    mutation_count: usize,
    link_add_journal_ready: Option<Rc<Cell<bool>>>,
    usable_default_interfaces: HashSet<String>,
    reassert_default_after_managed_replace: Option<String>,
    reassertions_remaining: usize,
    reassertions_armed: bool,
    fail_route_replace_once: Option<String>,
}

impl FakeRunner {
    fn existing() -> Self {
        let mut endpoint_routes = BTreeMap::new();
        endpoint_routes.insert(
            "198.51.100.20/32".to_string(),
            vec!["198.51.100.20/32 via 10.77.0.1 dev nvwg0 src 10.77.0.2 metric 7".to_string()],
        );
        Self {
            state: FakeNetworkState {
                link_exists: true,
                address: Some("10.77.0.2/24".to_string()),
                wireguard_config: "[Interface]\nListenPort = 41194\n".to_string(),
                mtu: 1380,
                up: true,
                endpoint_routes,
                table_routes: vec![
                    "default via 10.77.0.1 dev nvwg0 metric 9".to_string(),
                    "203.0.113.0/24 dev eth9 metric 31".to_string(),
                ],
                main_routes: vec![
                    "default via 192.0.2.1 dev eth0 src 192.0.2.10 metric 10".to_string(),
                    "default via 203.0.113.1 dev eth1 src 203.0.113.10 metric 20".to_string(),
                ],
                policy_rule_present: true,
            },
            commands: Vec::new(),
            stdin_commands: Vec::new(),
            table_missing_when_empty: false,
            table_error: None,
            fail_route_cache_once: false,
            fail_showconf: false,
            fail_link_delete: false,
            fail_restore_endpoint: false,
            fail_after_mutation: None,
            mutation_count: 0,
            link_add_journal_ready: None,
            usable_default_interfaces: ["eth0", "eth1", "eth2", "wlan0"]
                .into_iter()
                .map(str::to_string)
                .collect(),
            reassert_default_after_managed_replace: None,
            reassertions_remaining: 0,
            reassertions_armed: false,
            fail_route_replace_once: None,
        }
    }

    fn success(stdout: impl Into<String>) -> LinuxCommandOutput {
        LinuxCommandOutput {
            success: true,
            code: Some(0),
            stdout: stdout.into(),
            stderr: String::new(),
        }
    }

    fn failure(code: i32, stderr: impl Into<String>) -> LinuxCommandOutput {
        LinuxCommandOutput {
            success: false,
            code: Some(code),
            stdout: String::new(),
            stderr: stderr.into(),
        }
    }

    fn mutation_result(&mut self) -> LinuxCommandOutput {
        self.mutation_count += 1;
        if self.fail_after_mutation == Some(self.mutation_count) {
            self.fail_after_mutation = None;
            Self::failure(
                5,
                format!("synthetic failure after mutation {}", self.mutation_count),
            )
        } else {
            Self::success("")
        }
    }

    fn route_replace(&mut self, args: &[String]) -> Result<LinuxCommandOutput> {
        let mut route = args[3..].to_vec();
        let table = route
            .windows(2)
            .position(|window| window[0] == "table")
            .map(|index| {
                let table = route[index + 1].clone();
                route.truncate(index);
                table
            });
        let line = route.join(" ");
        if self
            .fail_route_replace_once
            .as_ref()
            .is_some_and(|needle| line.contains(needle))
        {
            self.fail_route_replace_once = None;
            return Ok(Self::failure(5, "synthetic route replacement failure"));
        }
        if line.contains("via 10.77.0.1 dev nvwg0")
            && self.state.address.as_deref() != Some("10.77.0.2/24")
        {
            return Ok(Self::failure(2, "Error: Nexthop has invalid gateway."));
        }
        if self.fail_restore_endpoint && line.contains("via 10.77.0.1 dev nvwg0") {
            return Ok(Self::failure(5, "synthetic endpoint restore failure"));
        }
        if table.as_deref() == Some("51888") {
            replace_route(&mut self.state.table_routes, line);
        } else if route.first().is_some_and(|target| target == "default") {
            replace_route(&mut self.state.main_routes, line);
        } else if let Some(target) = route.first() {
            self.state
                .endpoint_routes
                .insert(target.clone(), vec![line]);
        }
        Ok(self.mutation_result())
    }
}

impl LinuxCommandRunner for FakeRunner {
    fn output(&mut self, program: &str, args: &[String]) -> Result<LinuxCommandOutput> {
        self.commands.push((program.to_string(), args.to_vec()));
        let joined = args.join(" ");

        if program == "wg" && args.first().is_some_and(|arg| arg == "showconf") {
            if self.fail_showconf {
                return Ok(Self::failure(1, "Unable to access interface"));
            }
            return Ok(Self::success(self.state.wireguard_config.clone()));
        }
        if program == "wg" && args.first().is_some_and(|arg| arg == "set") {
            self.state.wireguard_config = "[Interface]\nPrivateKey = managed\n".to_string();
            return Ok(self.mutation_result());
        }

        match joined.as_str() {
            "-4 route show default" => {
                if self.reassertions_armed
                    && self.reassertions_remaining > 0
                    && let Some(route) = self.reassert_default_after_managed_replace.as_ref()
                {
                    if !self.state.main_routes.contains(route) {
                        self.state.main_routes.push(route.clone());
                    }
                    self.reassertions_remaining -= 1;
                }
                return Ok(Self::success(self.state.main_routes.join("\n") + "\n"));
            }
            "link show dev nvwg0" => {
                return Ok(if self.state.link_exists {
                    Self::success("")
                } else {
                    Self::failure(1, "Device \"nvwg0\" does not exist.")
                });
            }
            "link add dev nvwg0 type wireguard" => {
                if self
                    .link_add_journal_ready
                    .as_ref()
                    .is_some_and(|ready| !ready.get())
                {
                    return Ok(Self::failure(
                        5,
                        "link add reached before durable cleanup intent",
                    ));
                }
                self.state.link_exists = true;
                return Ok(self.mutation_result());
            }
            "link del dev nvwg0" => {
                if self.fail_link_delete {
                    return Ok(Self::failure(5, "synthetic link deletion failure"));
                }
                self.state.link_exists = false;
                return Ok(self.mutation_result());
            }
            "-o address show dev nvwg0" => {
                let output = self
                    .state
                    .address
                    .as_ref()
                    .map_or_else(String::new, |address| {
                        format!("7: nvwg0    inet {address} scope global nvwg0\n")
                    });
                return Ok(Self::success(output));
            }
            "-j link show dev nvwg0" => {
                let flags = if self.state.up { r#"["UP"]"# } else { "[]" };
                return Ok(Self::success(format!(
                    r#"[{{"ifname":"nvwg0","flags":{flags},"mtu":{}}}]"#,
                    self.state.mtu
                )));
            }
            "-4 route get 198.51.100.20" => {
                return Ok(Self::success(
                    "198.51.100.20 via 192.0.2.1 dev eth0 src 192.0.2.10\n",
                ));
            }
            "-4 route show 198.51.100.20/32" => {
                return Ok(Self::success(
                    self.state
                        .endpoint_routes
                        .get("198.51.100.20/32")
                        .cloned()
                        .unwrap_or_default()
                        .join("\n")
                        + "\n",
                ));
            }
            "-4 route show table 51888" => {
                if let Some(error) = self.table_error.as_ref() {
                    return Ok(Self::failure(2, error.clone()));
                }
                if self.table_missing_when_empty && self.state.table_routes.is_empty() {
                    return Ok(Self::failure(
                        2,
                        "Error: ipv4: FIB table does not exist.\nDump terminated",
                    ));
                }
                return Ok(Self::success(self.state.table_routes.join("\n") + "\n"));
            }
            "-4 rule show" => {
                let managed = self
                    .state
                    .policy_rule_present
                    .then_some("10888:\tfrom 10.44.0.0/16 lookup 51888\n");
                return Ok(Self::success(format!(
                    "0:\tfrom all lookup local\n{}32766:\tfrom all lookup main\n",
                    managed.unwrap_or("")
                )));
            }
            "address replace 10.77.0.2/32 dev nvwg0" => {
                self.state.address = Some("10.77.0.2/32".to_string());
                return Ok(self.mutation_result());
            }
            "address del 10.77.0.2/32 dev nvwg0" => {
                self.state.address = None;
                return Ok(self.mutation_result());
            }
            "address replace 10.77.0.2/24 dev nvwg0" => {
                self.state.address = Some("10.77.0.2/24".to_string());
                return Ok(self.mutation_result());
            }
            "link set mtu 1420 up dev nvwg0" => {
                self.state.mtu = 1420;
                self.state.up = true;
                return Ok(self.mutation_result());
            }
            "link set dev nvwg0 mtu 1380" => {
                self.state.mtu = 1380;
                return Ok(self.mutation_result());
            }
            "link set dev nvwg0 mtu 1420" => {
                self.state.mtu = 1420;
                return Ok(self.mutation_result());
            }
            "link set up dev nvwg0" => {
                self.state.up = true;
                return Ok(self.mutation_result());
            }
            "-4 route del default" => {
                self.state.main_routes.clear();
                return Ok(self.mutation_result());
            }
            "-4 route del default dev nvwg0" => {
                self.state
                    .main_routes
                    .retain(|route| !route.contains("dev nvwg0"));
                return Ok(self.mutation_result());
            }
            route if route.starts_with("-4 route del default ") => {
                let route = args[3..].join(" ");
                let existed = self
                    .state
                    .main_routes
                    .iter()
                    .any(|candidate| candidate == &route);
                self.state
                    .main_routes
                    .retain(|candidate| candidate != &route);
                return Ok(if existed {
                    self.mutation_result()
                } else {
                    Self::failure(2, "RTNETLINK answers: No such process")
                });
            }
            "-4 route flush default" => {
                self.state.main_routes.clear();
                return Ok(self.mutation_result());
            }
            "-4 route flush table 51888" => {
                self.state.table_routes.clear();
                return Ok(self.mutation_result());
            }
            "-4 rule add priority 10888 from 10.44.0.0/16 table 51888" => {
                self.state.policy_rule_present = true;
                return Ok(self.mutation_result());
            }
            "-4 rule del priority 10888 from 10.44.0.0/16 table 51888" => {
                self.state.policy_rule_present = false;
                return Ok(self.mutation_result());
            }
            "-4 route flush cache" => {
                if self.fail_route_cache_once {
                    self.fail_route_cache_once = false;
                    return Ok(Self::failure(5, "synthetic route-cache failure"));
                }
                return Ok(Self::success(""));
            }
            _ => {}
        }

        if args.starts_with(&strings(&["-4", "route", "replace"])) {
            let result = self.route_replace(args);
            if args.get(3).is_some_and(|target| target == "default")
                && args.windows(2).any(|window| window == ["dev", "nvwg0"])
                && self.reassert_default_after_managed_replace.is_some()
            {
                self.reassertions_armed = true;
            }
            return result;
        }
        if args.starts_with(&strings(&["-4", "route", "del"])) {
            let target = args[3].clone();
            self.state.endpoint_routes.remove(&target);
            return Ok(self.mutation_result());
        }
        Ok(Self::failure(
            127,
            format!("unhandled fake command: {program} {joined}"),
        ))
    }

    fn output_with_stdin(
        &mut self,
        program: &str,
        args: &[String],
        stdin: &[u8],
    ) -> Result<LinuxCommandOutput> {
        self.commands.push((program.to_string(), args.to_vec()));
        self.stdin_commands
            .push((program.to_string(), args.to_vec(), stdin.to_vec()));
        if program == "wg" && args == strings(&["setconf", "nvwg0", "/dev/stdin"]) {
            self.state.wireguard_config = std::str::from_utf8(stdin)?.to_string();
            return Ok(self.mutation_result());
        }
        Ok(Self::failure(
            127,
            format!("unhandled fake stdin command: {program} {}", args.join(" ")),
        ))
    }

    fn ipv4_default_route_is_usable(&mut self, route: &crate::LinuxDefaultRouteSpec) -> bool {
        self.usable_default_interfaces.contains(&route.dev)
    }
}

fn replace_route(routes: &mut Vec<String>, route: String) {
    let identity = route_identity(&route);
    routes.retain(|candidate| route_identity(candidate) != identity);
    routes.push(route);
}

fn route_identity(route: &str) -> (Option<&str>, Option<&str>) {
    let tokens = route.split_whitespace().collect::<Vec<_>>();
    let metric = tokens
        .windows(2)
        .find(|window| window[0] == "metric")
        .map(|window| window[1]);
    (tokens.first().copied(), metric)
}

fn lock_tests() -> std::sync::MutexGuard<'static, ()> {
    TEST_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn config() -> WireGuardExitConfig {
    WireGuardExitConfig {
        enabled: true,
        interface: "nvwg0".to_string(),
        address: "10.77.0.2/32".to_string(),
        private_key: "private-key".to_string(),
        peer_public_key: "peer-key".to_string(),
        endpoint: "198.51.100.20:51820".to_string(),
        allowed_ips: vec!["0.0.0.0/0".to_string()],
        mtu: 1420,
        ..WireGuardExitConfig::default()
    }
}

fn command_index(runner: &FakeRunner, needle: &[&str]) -> usize {
    runner
        .commands
        .iter()
        .position(|(_, args)| args == &strings(needle))
        .unwrap_or_else(|| panic!("missing command: {needle:?}"))
}

#[test]
fn endpoint_resolution_is_pinned_once_for_kernel_and_bypass_ownership() {
    let _guard = lock_tests();
    let mut runner = FakeRunner::existing();
    let initial = runner.state.clone();
    let mut desired = config();
    desired.endpoint = "vpn.example.test:51820".to_string();
    let resolver_calls = Cell::new(0);

    let runtime = apply_linux_wireguard_exit_upstream_with_journal(
        &mut runner,
        &desired,
        "10.44.0.0/16",
        None,
        Some("default via 192.0.2.1 dev eth0 src 192.0.2.10 metric 10"),
        |_| {
            let call = resolver_calls.get();
            resolver_calls.set(call + 1);
            Ok(if call == 0 {
                "198.51.100.20:51820".parse().expect("first DNS answer")
            } else {
                "203.0.113.20:51820"
                    .parse()
                    .expect("alternating DNS answer")
            })
        },
        |_| Ok(()),
    )
    .expect("pinned endpoint apply");

    assert_eq!(
        resolver_calls.get(),
        1,
        "endpoint DNS must run exactly once"
    );
    assert!(
        runner
            .state
            .wireguard_config
            .contains("Endpoint = 198.51.100.20:51820")
    );
    assert!(!runner.state.wireguard_config.contains("vpn.example.test"));
    assert!(
        runner
            .state
            .endpoint_routes
            .contains_key("198.51.100.20/32")
    );
    assert!(!runner.state.endpoint_routes.contains_key("203.0.113.20/32"));

    cleanup_linux_wireguard_exit_upstream_with(&mut runner, &runtime).expect("exact cleanup");
    assert_eq!(runner.state, initial);
}

#[test]
fn endpoint_resolution_failure_precedes_every_kernel_mutation() {
    let _guard = lock_tests();
    let mut runner = FakeRunner::existing();
    let initial = runner.state.clone();
    let mut desired = config();
    desired.endpoint = "unresolvable.example.test:51820".to_string();

    let error = apply_linux_wireguard_exit_upstream_with_journal(
        &mut runner,
        &desired,
        "10.44.0.0/16",
        None,
        Some("default via 192.0.2.1 dev eth0 src 192.0.2.10 metric 10"),
        |_| Err(anyhow!("synthetic endpoint resolution failure")),
        |_| Ok(()),
    )
    .expect_err("resolver failure");

    assert!(format!("{error:#}").contains("synthetic endpoint resolution failure"));
    assert!(runner.commands.is_empty());
    assert!(runner.stdin_commands.is_empty());
    assert_eq!(runner.mutation_count, 0);
    assert_eq!(runner.state, initial);
}

#[test]
#[cfg(target_os = "linux")]
fn serialized_reapply_crash_repairs_rollback_before_prior_runtime_cleanup() {
    let _guard = lock_tests();
    let mut runner = FakeRunner::existing();
    runner
        .state
        .table_routes
        .retain(|route| !route.starts_with("default "));
    let initial = runner.state.clone();
    let previous_runtime = apply_linux_wireguard_exit_upstream_with(
        &mut runner,
        &config(),
        "10.44.0.0/16",
        None,
        Some("default via 192.0.2.1 dev eth0 src 192.0.2.10 metric 10"),
    )
    .expect("initial WireGuard apply");
    let mut durable = crate::LinuxNetworkCleanupState {
        iface: "nvpn0".to_string(),
        exit_node_runtime: crate::LinuxExitNodeRuntime {
            wireguard_exit: Some(previous_runtime.clone()),
            ..crate::LinuxExitNodeRuntime::default()
        },
        ..crate::LinuxNetworkCleanupState::default()
    };
    let mut replacement = config();
    replacement.peer_public_key = "replacement-peer-key".to_string();
    let mut serialized = None;

    let failure = apply_linux_wireguard_exit_upstream_with_journal(
        &mut runner,
        &replacement,
        "10.44.0.0/16",
        Some(&previous_runtime),
        Some("default via 192.0.2.1 dev eth0 src 192.0.2.10 metric 10"),
        super::super::resolve_linux_wireguard_exit_endpoint,
        |obligation| {
            crate::fips_private_mesh::retain_linux_wireguard_apply_cleanup(
                &mut durable.exit_node_runtime,
                Some(&previous_runtime),
                obligation,
            );
            serialized = Some(serde_json::to_vec(&durable)?);
            Err(anyhow!("synthetic process crash after durable write-ahead"))
        },
    )
    .expect_err("simulated crash boundary");
    assert!(format!("{failure:#}").contains("synthetic process crash"));

    let mut repaired: crate::LinuxNetworkCleanupState = serde_json::from_slice(
        serialized
            .as_deref()
            .expect("write-ahead state was serialized"),
    )
    .expect("deserialize process-boundary cleanup state");
    assert_eq!(
        repaired
            .exit_node_runtime
            .pending_wireguard_exit_cleanup
            .len(),
        1
    );
    assert!(
        repaired.exit_node_runtime.wireguard_exit.is_some(),
        "the prior active runtime must be durable beside the apply rollback"
    );

    let runtime_cleanup_calls = Cell::new(0);
    crate::fips_private_mesh::cleanup_linux_wireguard_state_with(
        &mut repaired.exit_node_runtime,
        |_| Err(anyhow!("synthetic first rollback failure")),
        |_| {
            runtime_cleanup_calls.set(runtime_cleanup_calls.get() + 1);
            Ok(())
        },
    )
    .expect_err("failed transaction rollback remains pending");
    assert_eq!(runtime_cleanup_calls.get(), 0);
    assert!(repaired.exit_node_runtime.wireguard_exit.is_some());
    assert_eq!(
        repaired
            .exit_node_runtime
            .pending_wireguard_exit_cleanup
            .len(),
        1
    );

    let runner = RefCell::new(runner);
    crate::fips_private_mesh::cleanup_linux_wireguard_state_with(
        &mut repaired.exit_node_runtime,
        |obligation| {
            cleanup_linux_wireguard_exit_obligation_with(&mut *runner.borrow_mut(), obligation)
        },
        |runtime| cleanup_linux_wireguard_exit_upstream_with(&mut *runner.borrow_mut(), runtime),
    )
    .expect("retry rolls back the transaction before cleaning the prior runtime");
    let runner = runner.into_inner();

    assert!(
        repaired
            .exit_node_runtime
            .pending_wireguard_exit_cleanup
            .is_empty()
    );
    assert!(repaired.exit_node_runtime.wireguard_exit.is_none());
    assert_eq!(runner.state, initial);
    assert!(
        !runner
            .state
            .main_routes
            .iter()
            .any(|route| route == "default dev nvwg0 src 10.77.0.2"),
        "crash repair must not leave the restored old WireGuard default active"
    );
}

#[test]
fn failed_apply_restores_exact_state_and_address_before_via_routes() {
    let _guard = lock_tests();
    let mut runner = FakeRunner::existing();
    let initial = runner.state.clone();
    runner.fail_route_cache_once = true;

    let error = apply_linux_wireguard_exit_upstream_with(
        &mut runner,
        &config(),
        "10.44.0.0/16",
        None,
        Some("default via 192.0.2.1 dev eth0 src 192.0.2.10 metric 10"),
    )
    .expect_err("final apply failure must roll back");

    assert!(error.to_string().contains("synthetic route-cache failure"));
    assert_eq!(runner.state, initial);
    assert!(
        command_index(
            &runner,
            &["address", "replace", "10.77.0.2/24", "dev", "nvwg0"]
        ) < command_index(
            &runner,
            &[
                "-4",
                "route",
                "replace",
                "198.51.100.20/32",
                "via",
                "10.77.0.1",
                "dev",
                "nvwg0",
                "src",
                "10.77.0.2",
                "metric",
                "7",
            ]
        ),
        "old prefix must be restored before its dependent via route"
    );
}

#[test]
fn failure_after_each_apply_mutation_restores_exact_existing_state() {
    let _guard = lock_tests();
    let mut successful = FakeRunner::existing();
    let initial = successful.state.clone();
    let runtime = apply_linux_wireguard_exit_upstream_with(
        &mut successful,
        &config(),
        "10.44.0.0/16",
        None,
        Some("default via 192.0.2.1 dev eth0 src 192.0.2.10 metric 10"),
    )
    .expect("successful transaction");
    let apply_mutations = successful.mutation_count;
    assert!(apply_mutations >= 7, "test must cover the full apply path");
    cleanup_linux_wireguard_exit_upstream_with(&mut successful, &runtime).expect("cleanup");
    assert_eq!(successful.state, initial);

    for fail_after in 1..=apply_mutations {
        let mut runner = FakeRunner::existing();
        let initial = runner.state.clone();
        runner.fail_after_mutation = Some(fail_after);
        let error = apply_linux_wireguard_exit_upstream_with(
            &mut runner,
            &config(),
            "10.44.0.0/16",
            None,
            Some("default via 192.0.2.1 dev eth0 src 192.0.2.10 metric 10"),
        )
        .expect_err("injected post-mutation failure");
        let error_chain = format!("{error:#}");
        assert!(
            error_chain.contains("synthetic failure after mutation"),
            "unexpected failure {fail_after}: {error:#}"
        );
        assert_eq!(
            runner.state, initial,
            "state drift after mutation {fail_after}"
        );
    }
}

#[test]
fn post_apply_cleanup_restores_existing_interface_and_unowned_state() {
    let _guard = lock_tests();
    let mut runner = FakeRunner::existing();
    let initial = runner.state.clone();
    let runtime = apply_linux_wireguard_exit_upstream_with(
        &mut runner,
        &config(),
        "10.44.0.0/16",
        None,
        Some("default via 192.0.2.1 dev eth0 src 192.0.2.10 metric 10"),
    )
    .expect("apply");

    cleanup_linux_wireguard_exit_upstream_with(&mut runner, &runtime)
        .expect("inbound-guard failure cleanup");
    assert_eq!(runner.state, initial);
    assert!(
        !runner.commands.iter().any(|(_, args)| {
            args == &strings(&[
                "-4",
                "rule",
                "del",
                "priority",
                "10888",
                "from",
                "10.44.0.0/16",
                "table",
                "51888",
            ])
        }),
        "a preexisting exact policy rule is not owned"
    );
}

#[test]
fn already_active_alternate_underlay_refresh_preserves_all_cleanup_defaults() {
    let _guard = lock_tests();
    let mut runner = FakeRunner::existing();
    let initial = runner.state.clone();
    let primary = initial.main_routes[0].clone();
    let secondary = initial.main_routes[1].clone();
    let mut runtime = apply_linux_wireguard_exit_upstream_with(
        &mut runner,
        &config(),
        "10.44.0.0/16",
        None,
        Some(&primary),
    )
    .expect("initial primary apply");
    assert!(
        runner
            .state
            .main_routes
            .iter()
            .all(|route| route.contains("dev nvwg0")),
        "strict exit must remove every physical main default"
    );

    runtime.refresh_underlay_default_route(secondary.clone());
    let runtime = apply_linux_wireguard_exit_upstream_with(
        &mut runner,
        &config(),
        "10.44.0.0/16",
        Some(&runtime),
        Some(&secondary),
    )
    .expect("refresh onto already-active secondary");

    assert_eq!(
        runner.state.endpoint_routes["198.51.100.20/32"],
        vec!["198.51.100.20/32 via 203.0.113.1 dev eth1 src 203.0.113.10".to_string()],
        "the endpoint bypass must move to the selected alternate underlay"
    );
    assert_eq!(
        runtime.previous_main_default_routes, initial.main_routes,
        "choosing an already-cached route must not discard another cleanup default"
    );
    cleanup_linux_wireguard_exit_upstream_with(&mut runner, &runtime).expect("cleanup");
    assert_eq!(runner.state, initial);
}

#[test]
fn strict_default_apply_tolerates_a_disappeared_captured_underlay() {
    let _guard = lock_tests();
    let mut runner = FakeRunner::existing();
    let captured = runner.state.main_routes.clone();
    runner.state.main_routes.clear();

    apply_linux_wireguard_exit_default_route(
        &mut runner,
        "nvwg0",
        "10.77.0.2/32",
        &captured,
        |_| Ok(()),
    )
    .expect("a route disappearing between capture and delete is already invalidated");

    assert_eq!(
        runner.state.main_routes,
        vec!["default dev nvwg0 src 10.77.0.2".to_string()]
    );
}

#[test]
fn post_apply_audit_retains_and_removes_a_default_added_after_snapshot() {
    let _guard = lock_tests();
    let mut runner = FakeRunner::existing();
    let raced = "default via 198.51.100.1 dev eth2 src 198.51.100.42 metric 5".to_string();
    runner.reassert_default_after_managed_replace = Some(raced.clone());
    runner.reassertions_remaining = 1;

    let runtime = apply_linux_wireguard_exit_upstream_with(
        &mut runner,
        &config(),
        "10.44.0.0/16",
        None,
        Some("default via 192.0.2.1 dev eth0 src 192.0.2.10 metric 10"),
    )
    .expect("post-mutation audit closes the snapshot race");

    assert!(
        runner
            .state
            .main_routes
            .iter()
            .all(|route| route.contains("dev nvwg0"))
    );
    assert!(
        runtime.previous_main_default_routes.contains(&raced),
        "a raced route must be durable cleanup ownership before deletion"
    );
}

#[test]
fn post_apply_audit_fails_when_a_physical_default_keeps_reasserting() {
    let _guard = lock_tests();
    let mut runner = FakeRunner::existing();
    runner.reassert_default_after_managed_replace =
        Some("default via 198.51.100.1 dev eth2 src 198.51.100.42 metric 5".to_string());
    runner.reassertions_remaining = 4;

    let error = apply_linux_wireguard_exit_upstream_with(
        &mut runner,
        &config(),
        "10.44.0.0/16",
        None,
        Some("default via 192.0.2.1 dev eth0 src 192.0.2.10 metric 10"),
    )
    .expect_err("bounded audit must not report a leaking route set as healthy");

    assert!(
        error
            .to_string()
            .contains("unmanaged IPv4 defaults remain after three")
    );
}

#[test]
fn canonical_reconcile_removes_an_identical_reasserted_default() {
    let _guard = lock_tests();
    let mut runner = FakeRunner::existing();
    let initial = runner.state.clone();
    let primary = initial.main_routes[0].clone();
    let runtime = apply_linux_wireguard_exit_upstream_with(
        &mut runner,
        &config(),
        "10.44.0.0/16",
        None,
        Some(&primary),
    )
    .expect("initial strict exit");
    runner.state.main_routes.push(primary.clone());

    let runtime = apply_linux_wireguard_exit_upstream_with(
        &mut runner,
        &config(),
        "10.44.0.0/16",
        Some(&runtime),
        Some(&primary),
    )
    .expect("unchanged-fingerprint route reconciliation");

    assert!(
        runner
            .state
            .main_routes
            .iter()
            .all(|route| route.contains("dev nvwg0"))
    );
    cleanup_linux_wireguard_exit_upstream_with(&mut runner, &runtime).expect("cleanup");
    assert_eq!(runner.state, initial);
}

#[test]
fn same_interface_reconnect_uses_the_fresh_default_for_endpoint_replacement() {
    let _guard = lock_tests();
    let mut runner = FakeRunner::existing();
    let primary = runner.state.main_routes[0].clone();
    let runtime = apply_linux_wireguard_exit_upstream_with(
        &mut runner,
        &config(),
        "10.44.0.0/16",
        None,
        Some(&primary),
    )
    .expect("initial strict exit");
    let reconnected = "default via 192.0.2.254 dev eth0 metric 25".to_string();
    runner.state.main_routes.push(reconnected.clone());

    let runtime = apply_linux_wireguard_exit_upstream_with(
        &mut runner,
        &config(),
        "10.44.0.0/16",
        Some(&runtime),
        Some(&primary),
    )
    .expect("same-interface gateway refresh");

    assert_eq!(
        runner.state.endpoint_routes["198.51.100.20/32"],
        vec!["198.51.100.20/32 via 192.0.2.254 dev eth0".to_string()],
        "the old managed /32 must not override the exact fresh default captured immediately before replacement"
    );
    assert_eq!(
        runtime.previous_default_route.as_deref(),
        Some(reconnected.as_str())
    );
}

#[test]
fn refreshed_underlay_details_replace_only_the_same_interface() {
    let _guard = lock_tests();
    let mut runner = FakeRunner::existing();
    let primary = runner.state.main_routes[0].clone();
    let secondary = runner.state.main_routes[1].clone();
    let mut runtime = apply_linux_wireguard_exit_upstream_with(
        &mut runner,
        &config(),
        "10.44.0.0/16",
        None,
        Some(&primary),
    )
    .expect("initial apply");
    let refreshed_primary = "default via 192.0.2.254 dev eth0 src 192.0.2.44 metric 25".to_string();

    runtime.refresh_underlay_default_route(refreshed_primary.clone());

    assert!(!runtime.previous_main_default_routes.contains(&primary));
    assert!(runtime.previous_main_default_routes.contains(&secondary));
    assert!(
        runtime
            .previous_main_default_routes
            .contains(&refreshed_primary)
    );
    assert_eq!(
        runtime
            .underlay_default_route_for_interface("eth0")
            .expect("refreshed primary")
            .line,
        refreshed_primary
    );
}

#[test]
fn new_underlay_is_cached_without_losing_switch_back_route() {
    let _guard = lock_tests();
    let mut runner = FakeRunner::existing();
    let initial_defaults = runner.state.main_routes.clone();
    let primary = initial_defaults[0].clone();
    let new_underlay = "default via 10.42.0.1 dev wlan0 src 10.42.0.20 metric 700".to_string();
    let mut runtime = apply_linux_wireguard_exit_upstream_with(
        &mut runner,
        &config(),
        "10.44.0.0/16",
        None,
        Some(&primary),
    )
    .expect("initial primary apply");

    runner.state.main_routes.push(new_underlay.clone());
    runtime.refresh_underlay_default_route(new_underlay.clone());
    let mut runtime = apply_linux_wireguard_exit_upstream_with(
        &mut runner,
        &config(),
        "10.44.0.0/16",
        Some(&runtime),
        Some(&new_underlay),
    )
    .expect("refresh onto newly activated underlay");
    assert!(
        runner
            .state
            .main_routes
            .iter()
            .all(|route| route.contains("dev nvwg0")),
        "a newly appearing physical default must be cached then removed under strict exit"
    );

    assert!(
        initial_defaults
            .iter()
            .chain(std::iter::once(&new_underlay))
            .all(|route| runtime.previous_main_default_routes.contains(route)),
        "runtime must retain old defaults for switch-back and add the new cleanup route"
    );

    runtime.refresh_underlay_default_route(primary.clone());
    let runtime = apply_linux_wireguard_exit_upstream_with(
        &mut runner,
        &config(),
        "10.44.0.0/16",
        Some(&runtime),
        Some(&primary),
    )
    .expect("switch back to original underlay");
    assert_eq!(
        runtime.previous_default_route.as_deref(),
        Some(primary.as_str())
    );
    assert!(
        initial_defaults
            .iter()
            .chain(std::iter::once(&new_underlay))
            .all(|route| runtime.previous_main_default_routes.contains(route)),
        "switch-back must not forget any captured physical default"
    );
}

#[test]
fn cleanup_removes_exact_managed_default_when_a_new_physical_default_is_live() {
    let _guard = lock_tests();
    let mut runner = FakeRunner::existing();
    let runtime = apply_linux_wireguard_exit_upstream_with(
        &mut runner,
        &config(),
        "10.44.0.0/16",
        None,
        Some("default via 192.0.2.1 dev eth0 src 192.0.2.10 metric 10"),
    )
    .expect("apply");
    let fresh_physical = "default via 198.51.100.1 dev eth2 src 198.51.100.42".to_string();
    runner.state.main_routes.insert(0, fresh_physical.clone());

    cleanup_linux_wireguard_exit_upstream_with(&mut runner, &runtime)
        .expect("cleanup after underlay handoff");

    assert_eq!(
        runner.state.main_routes,
        vec![fresh_physical],
        "cleanup must delete the exact managed WG default, preserve the live physical route, \
         and avoid resurrecting obsolete captured defaults"
    );
    assert!(
        runner.commands.iter().any(|(_, args)| {
            args == &strings(&["-4", "route", "del", "default", "dev", "nvwg0"])
        })
    );
}

#[test]
fn handoff_cleanup_preserves_preexisting_default_on_managed_interface() {
    let _guard = lock_tests();
    let mut runner = FakeRunner::existing();
    let captured = vec![
        "default via 192.0.2.1 dev eth0 src 192.0.2.10 metric 10".to_string(),
        "default dev nvwg0 src 10.77.0.2 metric 30".to_string(),
    ];
    let fresh_physical = "default via 198.51.100.1 dev eth2 src 198.51.100.42 metric 5".to_string();
    runner.state.main_routes = vec![
        fresh_physical.clone(),
        "default dev nvwg0 src 10.77.0.2".to_string(),
    ];

    restore_linux_main_default_snapshot(&mut runner, "nvwg0", &captured)
        .expect("handoff-aware cleanup");

    assert_eq!(
        runner.state.main_routes,
        vec![fresh_physical, captured[1].clone()],
        "fresh physical state must win without destroying a captured unowned WG default"
    );
}

#[test]
fn cleanup_skips_a_stale_primary_and_restores_the_healthy_secondary() {
    let _guard = lock_tests();
    let mut runner = FakeRunner::existing();
    let captured = runner.state.main_routes.clone();
    runner.state.main_routes = vec!["default dev nvwg0 src 10.77.0.2".to_string()];
    runner.usable_default_interfaces.remove("eth0");

    restore_linux_main_default_snapshot(&mut runner, "nvwg0", &captured)
        .expect("restore healthy fallback");

    assert_eq!(
        runner.state.main_routes,
        vec![captured[1].clone()],
        "a link-down cached primary must not suppress or outrank the usable alternate"
    );
}

#[test]
fn cleanup_continues_restoring_alternates_after_one_route_fails() {
    let _guard = lock_tests();
    let mut runner = FakeRunner::existing();
    let captured = runner.state.main_routes.clone();
    runner.state.main_routes = vec!["default dev nvwg0 src 10.77.0.2".to_string()];
    runner.fail_route_replace_once = Some("dev eth0".to_string());

    let error = restore_linux_main_default_snapshot(&mut runner, "nvwg0", &captured)
        .expect_err("the failed route remains reportable");

    assert!(format!("{error:#}").contains("synthetic route replacement failure"));
    assert_eq!(
        runner.state.main_routes,
        vec![captured[1].clone()],
        "a failed stale/primary restore must not prevent the healthy alternate"
    );
}

#[test]
fn transaction_rollback_restores_exact_defaults_even_if_a_physical_route_survives() {
    let _guard = lock_tests();
    let mut runner = FakeRunner::existing();
    let captured = runner.state.main_routes.clone();
    runner.state.main_routes = vec![
        captured[1].clone(),
        "default dev nvwg0 src 10.77.0.2".to_string(),
    ];

    restore_linux_main_default_snapshot_exact(&mut runner, "nvwg0", &captured)
        .expect("exact transaction rollback");

    assert_eq!(runner.state.main_routes, captured);
    assert!(
        runner.commands.iter().any(|(_, args)| {
            args == &strings(&["-4", "route", "del", "default", "dev", "nvwg0"])
        })
    );
}

#[test]
fn transaction_rollback_preserves_a_new_physical_default() {
    let _guard = lock_tests();
    let mut runner = FakeRunner::existing();
    let captured = runner.state.main_routes.clone();
    let fresh = "default via 198.51.100.1 dev eth2 src 198.51.100.42 metric 5".to_string();
    runner.state.main_routes = vec![fresh.clone(), "default dev nvwg0 src 10.77.0.2".to_string()];

    restore_linux_main_default_snapshot_exact(&mut runner, "nvwg0", &captured)
        .expect("handoff-safe transaction rollback");

    assert!(runner.state.main_routes.contains(&fresh));
    assert!(
        captured
            .iter()
            .all(|route| runner.state.main_routes.contains(route))
    );
}

#[test]
fn apply_replaces_kernel_wireguard_peer_set_and_clears_omitted_fields() {
    let _guard = lock_tests();
    let mut runner = FakeRunner::existing();
    runner.state.wireguard_config = "\
[Interface]
PrivateKey = old-private

[Peer]
PublicKey = unrelated-peer
AllowedIPs = 10.99.0.0/16

[Peer]
PublicKey = peer-key
PresharedKey = stale-psk
AllowedIPs = 10.88.0.0/16
PersistentKeepalive = 55
"
    .to_string();
    let mut desired = config();
    desired.peer_preshared_key.clear();
    desired.persistent_keepalive_secs = 0;

    apply_linux_wireguard_exit_upstream_with(
        &mut runner,
        &desired,
        "10.44.0.0/16",
        None,
        Some("default via 192.0.2.1 dev eth0 src 192.0.2.10 metric 10"),
    )
    .expect("replace WireGuard configuration");

    assert!(
        runner
            .commands
            .iter()
            .any(|(program, args)| program == "wg"
                && args.first().is_some_and(|arg| arg == "setconf")),
        "production apply must use replacement semantics"
    );
    assert!(
        !runner
            .commands
            .iter()
            .any(|(program, args)| program == "wg" && args.first().is_some_and(|arg| arg == "set")),
        "incremental `wg set` leaves unrelated peers and omitted peer fields behind"
    );
    assert!(
        runner
            .state
            .wireguard_config
            .contains("PublicKey = peer-key")
    );
    assert!(!runner.state.wireguard_config.contains("unrelated-peer"));
    assert!(!runner.state.wireguard_config.contains("PresharedKey"));
    assert!(
        !runner
            .state
            .wireguard_config
            .contains("PersistentKeepalive")
    );
}

#[test]
fn wireguard_apply_and_rollback_stream_exact_configs_over_stdin() {
    let _guard = lock_tests();
    let mut runner = FakeRunner::existing();
    runner.state.wireguard_config = "\
[Interface]
PrivateKey = old-private
ListenPort = 41194

[Peer]
PublicKey = old-peer
PresharedKey = old-preshared
AllowedIPs = 10.99.0.0/16
"
    .to_string();
    let initial_config = runner.state.wireguard_config.clone();
    let desired = config();
    let desired_config = linux_wireguard_kernel_config(
        &desired,
        super::super::resolve_linux_wireguard_exit_endpoint(&desired.endpoint)
            .expect("numeric endpoint"),
    );
    runner.fail_route_cache_once = true;

    apply_linux_wireguard_exit_upstream_with(
        &mut runner,
        &desired,
        "10.44.0.0/16",
        None,
        Some("default via 192.0.2.1 dev eth0 src 192.0.2.10 metric 10"),
    )
    .expect_err("final apply failure must stream the exact rollback config");

    let setconf_calls = runner
        .stdin_commands
        .iter()
        .filter(|(program, args, _)| {
            program == "wg" && args == &strings(&["setconf", "nvwg0", "/dev/stdin"])
        })
        .collect::<Vec<_>>();
    assert_eq!(
        setconf_calls.len(),
        2,
        "apply and rollback must each use wg setconf /dev/stdin"
    );
    assert_eq!(
        setconf_calls[0].2,
        desired_config.as_bytes(),
        "apply must stream the desired config without rewriting it"
    );
    assert_eq!(
        setconf_calls[1].2,
        initial_config.as_bytes(),
        "rollback must stream the captured config byte-for-byte"
    );
    assert_eq!(runner.state.wireguard_config, initial_config);
    let setconf_commands = runner
        .commands
        .iter()
        .filter(|(program, args)| {
            program == "wg" && args.first().is_some_and(|arg| arg == "setconf")
        })
        .collect::<Vec<_>>();
    assert_eq!(setconf_commands.len(), 2);
    for (_, args) in setconf_commands {
        assert_eq!(
            args,
            &strings(&["setconf", "nvwg0", "/dev/stdin"]),
            "setconf must never receive a config file path"
        );
    }
    for (_, args) in &runner.commands {
        assert!(
            args.iter().all(|arg| ![
                "private-key",
                "peer-key",
                "old-private",
                "old-peer",
                "old-preshared"
            ]
            .iter()
            .any(|secret| arg.contains(secret))),
            "WireGuard secrets must never appear in command arguments: {args:?}"
        );
    }
}

#[test]
fn system_stdin_runner_reaps_early_failure_and_preserves_stderr() {
    let mut runner = SystemLinuxCommandRunner;
    let stdin = vec![b'x'; 1024 * 1024];
    let output = runner
        .output_with_stdin(
            "sh",
            &strings(&["-c", "printf 'setconf rejected' >&2; exit 23"]),
            &stdin,
        )
        .expect("child failure remains a command result even when stdin closes early");

    assert!(!output.success);
    assert_eq!(output.code, Some(23));
    assert_eq!(output.stderr, "setconf rejected");
}

#[test]
fn absent_policy_table_is_empty_but_other_route_errors_are_fatal() {
    let _guard = lock_tests();
    let missing = LinuxCommandOutput {
        success: false,
        code: Some(2),
        stdout: String::new(),
        stderr: "Error: ipv4: FIB table does not exist.\nDump terminated".to_string(),
    };
    assert!(linux_missing_fib_table_error(&missing));
    assert!(!linux_missing_fib_table_error(&LinuxCommandOutput {
        stderr: "RTNETLINK answers: Operation not permitted".to_string(),
        ..missing
    }));

    let mut runner = FakeRunner::existing();
    runner.state.table_routes.clear();
    runner.state.policy_rule_present = false;
    runner.table_missing_when_empty = true;
    let initial = runner.state.clone();
    let runtime = apply_linux_wireguard_exit_upstream_with(
        &mut runner,
        &config(),
        "10.44.0.0/16",
        None,
        Some("default via 192.0.2.1 dev eth0 src 192.0.2.10 metric 10"),
    )
    .expect("missing dedicated table is initially empty");
    cleanup_linux_wireguard_exit_upstream_with(&mut runner, &runtime).expect("cleanup");
    assert_eq!(runner.state, initial);

    let mut denied = FakeRunner::existing();
    denied.table_error = Some("RTNETLINK answers: Operation not permitted".to_string());
    let error = apply_linux_wireguard_exit_upstream_with(
        &mut denied,
        &config(),
        "10.44.0.0/16",
        None,
        None,
    )
    .expect_err("non-FIB route error must fail");
    assert!(error.to_string().contains("Operation not permitted"));
}

#[test]
fn capture_failure_after_link_creation_removes_link() {
    let _guard = lock_tests();
    let mut runner = FakeRunner::existing();
    runner.state.link_exists = false;
    runner.fail_showconf = true;
    let error = apply_linux_wireguard_exit_upstream_with(
        &mut runner,
        &config(),
        "10.44.0.0/16",
        None,
        None,
    )
    .expect_err("capture failure");
    assert!(error.to_string().contains("Unable to access interface"));
    assert!(!runner.state.link_exists);
}

#[test]
fn new_interface_cleanup_intent_precedes_link_creation() {
    let _guard = lock_tests();
    let journal_ready = Rc::new(Cell::new(false));
    let mut runner = FakeRunner::existing();
    runner.state.link_exists = false;
    runner.fail_showconf = true;
    runner.link_add_journal_ready = Some(Rc::clone(&journal_ready));
    let mut first_obligation = None;

    let failure = apply_linux_wireguard_exit_upstream_with_journal(
        &mut runner,
        &config(),
        "10.44.0.0/16",
        None,
        None,
        super::super::resolve_linux_wireguard_exit_endpoint,
        |obligation| {
            first_obligation.get_or_insert_with(|| obligation.clone());
            if matches!(
                obligation,
                LinuxWireGuardExitCleanupObligation::CreatedInterface { interface }
                    if interface == "nvwg0"
            ) {
                journal_ready.set(true);
            }
            Ok(())
        },
    )
    .expect_err("capture fails after the journaled interface creation");

    assert!(failure.to_string().contains("Unable to access interface"));
    assert!(
        journal_ready.get(),
        "link creation never received a cleanup intent"
    );
    assert!(matches!(
        first_obligation,
        Some(LinuxWireGuardExitCleanupObligation::CreatedInterface { ref interface })
            if interface == "nvwg0"
    ));
    assert!(!runner.state.link_exists);
}

#[test]
fn capture_failure_retains_new_interface_until_cleanup_can_finish() {
    let _guard = lock_tests();
    let mut runner = FakeRunner::existing();
    runner.state.link_exists = false;
    runner.fail_showconf = true;
    runner.fail_link_delete = true;

    let failure = apply_linux_wireguard_exit_upstream_with(
        &mut runner,
        &config(),
        "10.44.0.0/16",
        None,
        None,
    )
    .expect_err("capture and immediate interface cleanup fail");
    let (_, cleanup) = failure.into_parts();
    let mut cleanup = cleanup.expect("new interface cleanup obligation");
    assert!(runner.state.link_exists);

    runner.fail_link_delete = false;
    cleanup_linux_wireguard_exit_obligation_with(&mut runner, &mut cleanup)
        .expect("retained interface cleanup");
    assert!(!runner.state.link_exists);
}

#[test]
fn failed_transaction_retains_exact_rollback_until_retry_succeeds() {
    let _guard = lock_tests();
    let mut runner = FakeRunner::existing();
    let initial = runner.state.clone();
    runner.fail_route_cache_once = true;
    runner.fail_restore_endpoint = true;

    let failure = apply_linux_wireguard_exit_upstream_with(
        &mut runner,
        &config(),
        "10.44.0.0/16",
        None,
        Some("default via 192.0.2.1 dev eth0 src 192.0.2.10 metric 10"),
    )
    .expect_err("apply and immediate rollback fail");
    let (_, cleanup) = failure.into_parts();
    let mut cleanup = cleanup.expect("exact rollback obligation");

    runner.fail_restore_endpoint = false;
    cleanup_linux_wireguard_exit_obligation_with(&mut runner, &mut cleanup)
        .expect("retained exact rollback");
    assert_eq!(runner.state, initial);
}

#[test]
fn failed_link_creation_never_deletes_an_uncertain_same_name_interface() {
    let _guard = lock_tests();
    let mut runner = FakeRunner::existing();
    runner.state.link_exists = false;
    runner.fail_after_mutation = Some(1);
    let error = apply_linux_wireguard_exit_upstream_with(
        &mut runner,
        &config(),
        "10.44.0.0/16",
        None,
        None,
    )
    .expect_err("unacknowledged link creation");
    assert!(format!("{error:#}").contains("synthetic failure after mutation 1"));
    assert!(
        runner.state.link_exists,
        "a same-name interface observed after a failed add is not proven owned"
    );
}
