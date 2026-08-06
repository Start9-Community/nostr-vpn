fn build_network_setup(app: &AppRef, page: &gtk::Box, state: &NativeAppState) {
    match app.borrow().network_setup_mode {
        None => append_setup_choices(app, page),
        Some(NetworkSetupMode::Create) => {
            append_setup_back(app, page);
            append_create_network_card(app, page);
        }
        Some(NetworkSetupMode::Join) => {
            append_setup_back(app, page);
            append_join_network_card(app, page, state, None);
        }
    }
}

fn append_setup_choices(app: &AppRef, page: &gtk::Box) {
    let choices = card();
    let create = icon_text_button("Create Network", "list-add-symbolic");
    create.update_property(&[gtk::accessible::Property::Label(
        "nvpn-manual-join-create-network-choice",
    )]);
    {
        let app = app.clone();
        create.connect_clicked(move |_| {
            app.borrow_mut().network_setup_mode = Some(NetworkSetupMode::Create);
            render(&app);
        });
    }
    choices.append(&create);
    let join = icon_text_button("Join Network", "go-down-symbolic");
    join.update_property(&[gtk::accessible::Property::Label(
        "nvpn-manual-join-choose-join",
    )]);
    {
        let app = app.clone();
        join.connect_clicked(move |_| {
            app.borrow_mut().network_setup_mode = Some(NetworkSetupMode::Join);
            render(&app);
        });
    }
    choices.append(&join);
    page.append(&choices);
}

fn append_setup_back(app: &AppRef, page: &gtk::Box) {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let back = icon_text_button("Back", "go-previous-symbolic");
    {
        let app = app.clone();
        back.connect_clicked(move |_| {
            app.borrow_mut().network_setup_mode = None;
            render(&app);
        });
    }
    row.append(&back);
    page.append(&row);
}

fn append_create_network_card(app: &AppRef, page: &gtk::Box) {
    let create_card = card();
    section_header(&create_card, "Create Network", "list-add-symbolic");
    let create_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let name = entry("Network name", &app.borrow().drafts.new_network_name);
    name.update_property(&[gtk::accessible::Property::Label(
        "nvpn-manual-join-create-network-name",
    )]);
    {
        let app = app.clone();
        name.connect_changed(move |entry| {
            app.borrow_mut().drafts.new_network_name = entry.text().to_string();
        });
    }
    let create = icon_text_button("Create", "list-add-symbolic");
    create.update_property(&[gtk::accessible::Property::Label(
        "nvpn-manual-join-create-network-submit",
    )]);
    {
        let app = app.clone();
        create.connect_clicked(move |_| {
            let name = {
                let mut model = app.borrow_mut();
                let name = model.drafts.new_network_name.trim().to_string();
                model.drafts.new_network_name.clear();
                name
            };
            create_network(&app, name);
        });
    }
    create_row.append(&name);
    create_row.append(&create);
    create_card.append(&create_row);
    page.append(&create_card);
}

fn append_join_network_card(
    app: &AppRef,
    page: &gtk::Box,
    state: &NativeAppState,
    request_network: Option<&NativeNetworkState>,
) {
    let request_network = request_network.or_else(|| {
        state.networks.iter().find(|network| {
            network.outbound_join_request.is_some()
                || !network.join_request_qr_code_or_link.is_empty()
        })
    });
    let join_request = if state.join_request_qr_code_or_link.is_empty() {
        request_network
            .map(|network| network.join_request_qr_code_or_link.as_str())
            .unwrap_or("")
    } else {
        &state.join_request_qr_code_or_link
    };

    let join_card = card();
    section_header(&join_card, "Join Network", "go-down-symbolic");
    if !join_request.is_empty() {
        join_card.append(&qr::build(join_request, 220));
        let copy = icon_text_button("Copy request", "edit-copy-symbolic");
        {
            let request = join_request.to_string();
            copy.connect_clicked(move |_| copy_text(&request));
        }
        join_card.append(&copy);
    }

    let manual = gtk::Expander::new(Some("Manual join"));
    manual.update_property(&[gtk::accessible::Property::Label(
        "nvpn-manual-join-expander",
    )]);
    manual.set_expanded(app.borrow().manual_join_expanded);
    {
        let app = app.clone();
        manual.connect_expanded_notify(move |manual| {
            app.borrow_mut().manual_join_expanded = manual.is_expanded();
        });
    }
    let manual_body = gtk::Box::new(gtk::Orientation::Vertical, 8);
    let help = gtk::Label::new(Some(
        "Give the admin your Device ID. Enter their Device ID and Network ID here; they must add your Device ID too.",
    ));
    help.set_wrap(true);
    help.set_xalign(0.0);
    help.add_css_class("caption");
    help.add_css_class("dim-label");
    manual_body.append(&help);
    let own_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let own = gtk::Label::new(Some(&state.own_npub));
    own.update_property(&[gtk::accessible::Property::Label(
        "nvpn-manual-join-joiner-device-id-value",
    )]);
    own.set_hexpand(true);
    own.set_xalign(0.0);
    own.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
    own_row.append(&own);
    let copy_own = icon_text_button("Copy Device ID", "edit-copy-symbolic");
    {
        let value = state.own_npub.clone();
        copy_own.connect_clicked(move |_| copy_text(&value));
    }
    own_row.append(&copy_own);
    manual_body.append(&own_row);
    let admin = entry("Admin Device ID", &app.borrow().drafts.manual_admin_npub);
    admin.update_property(&[gtk::accessible::Property::Label(
        "nvpn-manual-join-admin-id",
    )]);
    {
        let app = app.clone();
        admin.connect_changed(move |entry| {
            app.borrow_mut().drafts.manual_admin_npub = entry.text().to_string();
        });
    }
    manual_body.append(&admin);
    let mesh = entry("Network ID", &app.borrow().drafts.manual_mesh_id);
    mesh.update_property(&[gtk::accessible::Property::Label(
        "nvpn-manual-join-network-id",
    )]);
    {
        let app = app.clone();
        mesh.connect_changed(move |entry| {
            app.borrow_mut().drafts.manual_mesh_id = entry.text().to_string();
        });
    }
    manual_body.append(&mesh);
    let add_manual = icon_text_button("Add manually", "list-add-symbolic");
    add_manual.update_property(&[gtk::accessible::Property::Label(
        "nvpn-manual-join-submit",
    )]);
    {
        let app = app.clone();
        add_manual.connect_clicked(move |_| {
            let (admin_npub, mesh_network_id) = {
                let model = app.borrow();
                (
                    model.drafts.manual_admin_npub.trim().to_string(),
                    normalize_network_id_input(&model.drafts.manual_mesh_id),
                )
            };
            if !is_valid_device_id(&admin_npub) || mesh_network_id.is_empty() {
                set_notice(&app, "Enter a valid admin Device ID and Network ID".to_string());
                return;
            }
            let state = dispatch(
                &app,
                NativeAppAction::ManualAddNetwork {
                    admin_npub,
                    mesh_network_id,
                },
            );
            if state.error.trim().is_empty() {
                {
                    let mut model = app.borrow_mut();
                    model.drafts.manual_admin_npub.clear();
                    model.drafts.manual_mesh_id.clear();
                    model.manual_join_expanded = false;
                }
                set_page(&app, Page::Devices);
            }
        });
    }
    manual_body.append(&add_manual);
    manual.set_child(Some(&manual_body));
    join_card.append(&manual);

    append_notice(app, &join_card, "Join");
    page.append(&join_card);
}

fn build_share_page(app: &AppRef, page: &gtk::Box, state: &NativeAppState) {
    let Some(network) = active_network(state).cloned() else {
        return;
    };

    if network.local_is_admin {
        page_title(page, "Link Device", "contact-new-symbolic");
        append_link_device_card(app, page, &network);
        append_join_requests(app, page, &network);
        return;
    }

    page_title(page, "Join Network", "go-down-symbolic");
    append_join_network_card(app, page, state, None);
}

fn append_link_device_card(app: &AppRef, page: &gtk::Box, network: &NativeNetworkState) {
    let link = card();
    section_header(&link, "Link Device", "contact-new-symbolic");

    let manual_help = gtk::Label::new(Some(
        "For manual join, share this admin Device ID and Network ID, then add the joining Device ID below.",
    ));
    manual_help.set_wrap(true);
    manual_help.set_xalign(0.0);
    manual_help.add_css_class("caption");
    manual_help.add_css_class("dim-label");
    link.append(&manual_help);
    for (label, selector, raw, shown) in [
        (
            "Admin Device ID",
            "nvpn-manual-join-admin-device-id-value",
            app.borrow().state.own_npub.clone(),
            app.borrow().state.own_npub.clone(),
        ),
        (
            "Network ID",
            "nvpn-manual-join-admin-network-id-value",
            network.network_id.clone(),
            display_network_id(&network.network_id),
        ),
    ] {
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let value = gtk::Label::new(Some(&format!("{label}: {shown}")));
        value.update_property(&[gtk::accessible::Property::Label(selector)]);
        value.set_hexpand(true);
        value.set_xalign(0.0);
        value.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
        row.append(&value);
        let copy = icon_text_button("Copy", "edit-copy-symbolic");
        copy.connect_clicked(move |_| copy_text(&raw));
        row.append(&copy);
        link.append(&row);
    }

    let request_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let request = entry(
        "Approval request or Device ID",
        &app.borrow().drafts.join_request,
    );
    {
        let app = app.clone();
        request.connect_changed(move |entry| {
            app.borrow_mut().drafts.join_request = entry.text().to_string();
        });
    }
    let import = icon_text_button("Import request", "document-open-symbolic");
    {
        let app = app.clone();
        let network_id = network.id.clone();
        import.connect_clicked(move |_| import_join_request_or_add_device(&app, network_id.clone()));
    }
    request_row.append(&request);
    request_row.append(&import);
    link.append(&request_row);

    let scan = icon_text_button("Scan approval request", "camera-photo-symbolic");
    {
        let app = app.clone();
        scan.connect_clicked(move |button| scan_join_request_qr(&app, button));
    }
    link.append(&scan);

    switch_row_enabled(
        app,
        &link,
        "Allow join requests",
        network.join_requests_enabled,
        network.local_is_admin,
        {
            let network_id = network.id.clone();
            move |enabled| NativeAppAction::SetNetworkJoinRequestsEnabled {
                network_id: network_id.clone(),
                enabled,
            }
        },
    );

    let manual = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let npub = entry("Joiner's Device ID", &app.borrow().drafts.participant_npub);
    npub.update_property(&[gtk::accessible::Property::Label(
        "nvpn-manual-join-admin-device-id",
    )]);
    {
        let app = app.clone();
        npub.connect_changed(move |entry| {
            app.borrow_mut().drafts.participant_npub = entry.text().to_string();
        });
    }
    let alias = entry("Name", &app.borrow().drafts.participant_alias);
    alias.update_property(&[gtk::accessible::Property::Label(
        "nvpn-manual-join-admin-device-name",
    )]);
    alias.set_width_chars(16);
    {
        let app = app.clone();
        alias.connect_changed(move |entry| {
            app.borrow_mut().drafts.participant_alias = entry.text().to_string();
        });
    }
    let add = icon_text_button("Add", "list-add-symbolic");
    add.update_property(&[gtk::accessible::Property::Label(
        "nvpn-manual-join-admin-submit",
    )]);
    {
        let app = app.clone();
        let network_id = network.id.clone();
        add.connect_clicked(move |_| add_participant_from_drafts(&app, network_id.clone()));
    }
    manual.append(&npub);
    manual.append(&alias);
    manual.append(&add);
    link.append(&manual);

    page.append(&link);
}

fn append_notice(app: &AppRef, parent: &gtk::Box, title: &str) {
    let notice = app.borrow().notice.clone();
    if !notice.trim().is_empty() {
        row_label(parent, title, &notice, "dialog-warning-symbolic");
    }
}

fn import_join_request_or_add_device(app: &AppRef, network_id: String) {
    let request = app.borrow().drafts.join_request.trim().to_string();
    if request.is_empty() {
        return;
    }
    let state = if is_valid_device_id(&request) {
        dispatch(
            app,
            NativeAppAction::AddParticipant {
                network_id,
                npub: request,
                alias: None,
            },
        )
    } else {
        dispatch(app, NativeAppAction::ImportJoinRequest { request })
    };
    if state.error.trim().is_empty() {
        {
            let mut model = app.borrow_mut();
            model.drafts.join_request.clear();
            model.notice.clear();
        }
        set_page(app, Page::Devices);
    }
}

fn add_participant_from_drafts(app: &AppRef, network_id: String) {
    let (npub, alias) = {
        let model = app.borrow();
        (
            model.drafts.participant_npub.trim().to_string(),
            model.drafts.participant_alias.trim().to_string(),
        )
    };
    if npub.is_empty() {
        return;
    }
    let state = dispatch(
        app,
        NativeAppAction::AddParticipant {
            network_id: network_id.clone(),
            npub: npub.clone(),
            alias: (!alias.is_empty()).then_some(alias),
        },
    );
    let added = manual_participant_added(&state, &network_id, &npub);
    if added {
        {
            let mut model = app.borrow_mut();
            model.drafts.participant_npub.clear();
            model.drafts.participant_alias.clear();
        }
        set_page(app, Page::Devices);
    }
}

fn manual_participant_added(state: &NativeAppState, network_id: &str, npub: &str) -> bool {
    state.networks.iter().any(|network| {
        network.id == network_id
            && network
                .participants
                .iter()
                .any(|participant| participant.npub == npub && participant.roster_accepted)
    })
}
