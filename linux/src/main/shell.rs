fn refresh_header(app: &AppRef, state: &NativeAppState) {
    let (label, dot, switch) = {
        let model = app.borrow();
        (
            model.header_status_label.clone(),
            model.header_status_dot.clone(),
            model.header_vpn_switch.clone(),
        )
    };

    label.set_text(&tray::vpn_status_text(state));

    let dot_visible =
        state.exit_node_blocked || state.exit_node_active || state.vpn_active || state.vpn_enabled;
    dot.set_visible(dot_visible);
    for class in ["ok", "warn", "bad"] {
        dot.remove_css_class(class);
    }
    if state.exit_node_blocked {
        dot.add_css_class("bad");
    } else if state.exit_node_active || state.vpn_active {
        dot.add_css_class("ok");
    } else if state.vpn_enabled {
        dot.add_css_class("warn");
    }

    switch.set_sensitive(state.vpn_control_supported && active_network(state).is_some());
    if switch.is_active() != state.vpn_enabled {
        switch.set_active(state.vpn_enabled);
    }
}

fn render(app: &AppRef) {
    app.borrow_mut().render_pending = false;
    sync_selected_device(app);

    let (sidebar, update_bar, content, state, page, rendered_page) = {
        let model = app.borrow();
        (
            model.sidebar.clone(),
            model.update_bar.clone(),
            model.content.clone(),
            model.state.clone(),
            model.page,
            model.rendered_page,
        )
    };
    let current_scroll_offset = current_content_scroll_offset(&content);
    let scroll_offset = {
        let mut model = app.borrow_mut();
        model
            .scroll_offsets
            .set(rendered_page, current_scroll_offset);
        model.rendered_page = page;
        model.scroll_offsets.get(page)
    };

    refresh_header(app, &state);
    clear_box(&sidebar);
    clear_box(&update_bar);
    clear_box(&content);
    build_sidebar(app, &sidebar, &state, page);
    build_update_stripe(app, &update_bar, &state);

    let scroll = gtk::ScrolledWindow::new();
    scroll.set_hscrollbar_policy(gtk::PolicyType::Never);
    scroll.set_vexpand(true);
    scroll.set_hexpand(true);

    let page_box = gtk::Box::new(gtk::Orientation::Vertical, 20);
    page_box.set_margin_top(28);
    page_box.set_margin_bottom(32);
    page_box.set_margin_start(28);
    page_box.set_margin_end(28);
    page_box.set_hexpand(true);
    page_box.set_valign(gtk::Align::Start);
    page_box.set_size_request(560, -1);

    match page {
        Page::Devices => build_devices_page(app, &page_box, &state),
        Page::Share => build_share_page(app, &page_box, &state),
        Page::ExitNodes => build_exit_nodes_page(app, &page_box, &state),
        Page::PaidRoutes => build_paid_routes_page(app, &page_box, &state),
        Page::Wallet => build_paid_route_wallet_page(app, &page_box, &state),
        Page::Settings => build_settings_page(app, &page_box, &state),
    }

    scroll.set_child(Some(&page_box));
    content.append(&scroll);
    restore_scroll_offset(&scroll, scroll_offset);
}

fn build_update_stripe(app: &AppRef, parent: &gtk::Box, state: &NativeAppState) {
    let update = app.borrow().update.clone();
    if !update.available {
        return;
    }

    let row = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    row.add_css_class("nvpn-update-stripe");
    row.set_valign(gtk::Align::Center);

    let title = gtk::Label::new(Some(&update_stripe_text(
        &update.version,
        &state.app_version,
    )));
    title.set_xalign(0.0);
    title.set_hexpand(true);
    title.set_ellipsize(gtk::pango::EllipsizeMode::End);
    row.append(&title);

    let auto_install = gtk::CheckButton::with_label("Install automatically");
    auto_install.set_active(update.auto_install);
    {
        let app = app.clone();
        auto_install.connect_toggled(move |button| {
            let enabled = button.is_active();
            {
                let mut model = app.borrow_mut();
                model.update.auto_install = enabled;
            }
            save_auto_install_updates(enabled);
            if enabled {
                download_update(&app);
            }
        });
    }
    row.append(&auto_install);

    let install = icon_text_button(
        if update.downloading {
            "Downloading"
        } else {
            "Install"
        },
        "folder-download-symbolic",
    );
    install.set_sensitive(
        update.available && update.asset.is_some() && !update.checking && !update.downloading,
    );
    {
        let app = app.clone();
        install.connect_clicked(move |_| download_update(&app));
    }
    row.append(&install);

    parent.append(&row);
}

fn update_stripe_text(version: &str, current: &str) -> String {
    let current = current.trim();
    if current.is_empty() {
        format!("Update available: {version}")
    } else {
        format!("Update available: {version} (you're on {current})")
    }
}

fn build_sidebar(app: &AppRef, sidebar: &gtk::Box, state: &NativeAppState, page: Page) {
    let has_incoming_join_requests = incoming_join_request_count(state) > 0;
    let mut pages = vec![
        (Page::Devices, "Devices".to_string(), ""),
        (Page::ExitNodes, "Internet".to_string(), ""),
    ];
    if paid_internet_available(state) {
        let wallet_title = if state
            .paid_route_market
            .wallet
            .navigation_balance_text
            .is_empty()
        {
            "Wallet".to_string()
        } else {
            format!(
                "Wallet {}",
                state.paid_route_market.wallet.navigation_balance_text
            )
        };
        pages.push((Page::Wallet, wallet_title, ""));
    }
    pages.push((Page::Settings, "Settings".to_string(), ""));
    for (target, title, icon) in pages {
        let button = nav_button(
            &title,
            icon,
            page == target,
            target == Page::Devices && has_incoming_join_requests,
        );
        let app = app.clone();
        button.connect_clicked(move |_| set_page(&app, target));
        sidebar.append(&button);
    }

    sidebar.append(&gtk::Separator::new(gtk::Orientation::Horizontal));

    if let Some(network) = active_network(state) {
        let summary = gtk::Box::new(gtk::Orientation::Vertical, 4);
        summary.add_css_class("nvpn-sidebar-summary");

        let name = gtk::Label::new(Some(&display_network_name(network)));
        name.add_css_class("caption-heading");
        name.set_xalign(0.0);
        name.set_ellipsize(gtk::pango::EllipsizeMode::End);
        summary.append(&name);

        let count = gtk::Label::new(Some(&format!(
            "{} of {} connected",
            state.connected_peer_count, state.expected_peer_count
        )));
        count.add_css_class("caption");
        count.add_css_class("dim-label");
        count.set_xalign(0.0);
        summary.append(&count);

        sidebar.append(&summary);
    }

    let spacer = gtk::Box::new(gtk::Orientation::Vertical, 0);
    spacer.set_vexpand(true);
    sidebar.append(&spacer);

    let status = gtk::Label::new(Some(&state.vpn_status));
    status.add_css_class("caption");
    status.add_css_class("dim-label");
    status.set_xalign(0.0);
    status.set_wrap(true);
    sidebar.append(&status);
}
