pub(super) fn build_paid_route_wallet_card(app: &AppRef, page: &gtk::Box, state: &NativeAppState) {
    let wallet = &state.paid_route_market.wallet;
    let card = card();
    let header = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    header.set_valign(gtk::Align::Center);
    section_header(&header, "Wallet", "");
    let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    spacer.set_hexpand(true);
    header.append(&spacer);
    let refresh = icon_text_button("Refresh", "view-refresh-symbolic");
    {
        let app = app.clone();
        refresh.connect_clicked(move |_| {
            dispatch(
                &app,
                NativeAppAction::RefreshPaidRouteWallet { refresh: true },
            );
        });
    }
    header.append(&refresh);
    card.append(&header);

    if wallet.balance_known {
        let balance = gtk::Label::new(Some(&non_empty_or(
            &wallet.total_balance_text,
            &format_paid_route_msat(wallet.total_balance_msat),
        )));
        balance.set_xalign(0.0);
        balance.add_css_class("title-1");
        card.append(&balance);
    }
    if state.wallet_fiat_enabled && !wallet.fiat_balance_text.is_empty() {
        detail_row(&card, "Bitcoin", &format_paid_route_msat(wallet.total_balance_msat));
        detail_row(
            &card,
            "Rate",
            &format!(
                "{} · {}",
                wallet.exchange_rate_text, wallet.exchange_rate_sources
            ),
        );
    }
    detail_row(
        &card,
        "Status",
        &paid_route_wallet_action_text(&wallet.last_action),
    );
    if wallet.last_action.kind == "topup" && !wallet.last_action.payment_request.is_empty() {
        card.append(&qr::build(&wallet.last_action.payment_request, 220));
        let copy = icon_text_button("Copy invoice", "edit-copy-symbolic");
        {
            let invoice = wallet.last_action.payment_request.clone();
            copy.connect_clicked(move |_| copy_text(&invoice));
        }
        card.append(&copy);
    }

    wallet_form_row(
        app,
        &card,
        "Mint URL",
        "Add",
        "list-add-symbolic",
        |drafts| drafts.paid_route_mint_url.clone(),
    );
    let transfer_stack = gtk::Stack::new();
    let transfer_switcher = gtk::StackSwitcher::new();
    transfer_switcher.set_stack(Some(&transfer_stack));
    transfer_switcher.set_halign(gtk::Align::Center);
    card.append(&transfer_switcher);

    let receive = gtk::Box::new(gtk::Orientation::Vertical, 8);
    let has_mint = !wallet.default_mint.trim().is_empty();
    if !has_mint {
        let notice = gtk::Label::new(Some("Add a mint before using Lightning."));
        notice.set_xalign(0.0);
        notice.add_css_class("dim-label");
        receive.append(&notice);
    }
    wallet_amount_row(
        app,
        &receive,
        "Amount in sats",
        "Create Invoice",
        "go-down-symbolic",
        WalletAction::TopUp,
        has_mint,
    );
    wallet_token_row(app, &receive);
    transfer_stack.add_titled(&receive, Some("receive"), "Receive");

    let send = gtk::Box::new(gtk::Orientation::Vertical, 8);
    if !has_mint {
        let notice = gtk::Label::new(Some("Add a mint before sending."));
        notice.set_xalign(0.0);
        notice.add_css_class("dim-label");
        send.append(&notice);
    }
    wallet_withdraw_row(app, &send);
    wallet_amount_row(
        app,
        &send,
        "Amount in sats",
        "Export",
        "document-send-symbolic",
        WalletAction::Send,
        has_mint,
    );
    transfer_stack.add_titled(&send, Some("send"), "Send");
    card.append(&transfer_stack);

    section_header(&card, "Mints", "");
    if wallet.mints.is_empty() {
        empty_row(&card, "No wallet mints");
    } else {
        for mint in &wallet.mints {
            paid_route_mint_row(app, &card, mint);
        }
    }
    page.append(&card);
}

fn wallet_form_row<F>(
    app: &AppRef,
    parent: &gtk::Box,
    placeholder: &str,
    button: &str,
    icon: &str,
    value: F,
) where
    F: Fn(&Drafts) -> String,
{
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let input = entry(placeholder, &value(&app.borrow().drafts));
    {
        let app = app.clone();
        input.connect_changed(move |entry| {
            app.borrow_mut().drafts.paid_route_mint_url = entry.text().to_string();
        });
    }
    let add = icon_text_button(button, icon);
    {
        let app = app.clone();
        add.connect_clicked(move |_| {
            let url = app.borrow().drafts.paid_route_mint_url.trim().to_string();
            if !url.is_empty() {
                dispatch(
                    &app,
                    NativeAppAction::AddPaidRouteWalletMint { url, label: None },
                );
            }
        });
    }
    row.append(&input);
    row.append(&add);
    parent.append(&row);
}

#[derive(Clone, Copy)]
enum WalletAction {
    TopUp,
    Send,
}

fn wallet_amount_row(
    app: &AppRef,
    parent: &gtk::Box,
    placeholder: &str,
    button: &str,
    icon: &str,
    action: WalletAction,
    has_mint: bool,
) {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let value = {
        let drafts = &app.borrow().drafts;
        match action {
            WalletAction::TopUp => drafts.paid_route_top_up_amount.clone(),
            WalletAction::Send => drafts.paid_route_send_amount.clone(),
        }
    };
    let input = entry(placeholder, &value);
    {
        let app = app.clone();
        input.connect_changed(move |entry| {
            let mut model = app.borrow_mut();
            match action {
                WalletAction::TopUp => {
                    model.drafts.paid_route_top_up_amount = entry.text().to_string();
                }
                WalletAction::Send => {
                    model.drafts.paid_route_send_amount = entry.text().to_string();
                }
            }
        });
    }
    let submit = icon_text_button(button, icon);
    submit.set_sensitive(has_mint);
    {
        let app = app.clone();
        submit.connect_clicked(move |_| {
            let amount = {
                let model = app.borrow();
                let amount_text = match action {
                    WalletAction::TopUp => &model.drafts.paid_route_top_up_amount,
                    WalletAction::Send => &model.drafts.paid_route_send_amount,
                };
                parse_positive_u64(amount_text)
            };
            let Some(amount_sat) = amount else {
                return;
            };
            dispatch(
                &app,
                match action {
                    WalletAction::TopUp => NativeAppAction::TopUpPaidRouteWallet {
                        mint_url: None,
                        amount_sat,
                    },
                    WalletAction::Send => NativeAppAction::SendPaidRouteWalletToken {
                        mint_url: None,
                        amount_sat,
                    },
                },
            );
        });
    }
    row.append(&input);
    row.append(&submit);
    parent.append(&row);
}

fn wallet_token_row(app: &AppRef, parent: &gtk::Box) {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let input = entry("Paste token", &app.borrow().drafts.paid_route_token);
    {
        let app = app.clone();
        input.connect_changed(move |entry| {
            let value = entry.text().to_string();
            app.borrow_mut().drafts.paid_route_token = value.clone();
            if is_likely_cashu_token(&value) {
                let token = value.trim().to_string();
                app.borrow_mut().drafts.paid_route_token.clear();
                entry.set_text("");
                preview_and_confirm_wallet_token(&app, token);
            }
        });
    }
    let scan = icon_text_button("Scan QR", "camera-photo-symbolic");
    {
        let app_for_click = app.clone();
        scan.connect_clicked(move |button| {
            let parent = button
                .root()
                .and_then(|root| root.downcast::<gtk::Window>().ok());
            let app_for_result = app_for_click.clone();
            let app_for_error = app_for_click.clone();
            qr_scan::open_scanner(
                parent.as_ref(),
                move |value| {
                    if is_likely_cashu_token(&value) {
                        preview_and_confirm_wallet_token(
                            &app_for_result,
                            value.trim().to_string(),
                        );
                    } else {
                        set_notice(&app_for_result, "Not a Cashu token".to_string());
                    }
                },
                move |error| set_notice(&app_for_error, error),
            );
        });
    }
    row.append(&input);
    row.append(&scan);
    parent.append(&row);
}

fn preview_and_confirm_wallet_token(app: &AppRef, token: String) {
    let state = dispatch(
        app,
        NativeAppAction::PreviewPaidRouteWalletToken {
            token: token.clone(),
        },
    );
    if !state.error.is_empty() {
        return;
    }
    let preview = &state.paid_route_market.wallet.last_action;
    if preview.kind != "preview" {
        return;
    }
    let memo = if preview.token_memo.is_empty() {
        String::new()
    } else {
        format!("\nMemo: {}", preview.token_memo)
    };
    let body = format!(
        "Amount: {}\nMint: {}{}\nStatus: {}",
        preview.amount_text, preview.mint_url, memo, preview.status_text
    );
    let dialog = adw::AlertDialog::new(Some("Redeem token?"), Some(&body));
    if preview.token_redeemable {
        dialog.add_responses(&[("cancel", "Cancel"), ("redeem", "Redeem")]);
        dialog.set_close_response("cancel");
        dialog.set_default_response(Some("redeem"));
        let app = app.clone();
        dialog.connect_response(Some("redeem"), move |_, _| {
            let state = dispatch(
                &app,
                NativeAppAction::ReceivePaidRouteWalletToken {
                    token: token.clone(),
                },
            );
            if !state.error.is_empty() {
                let error = adw::AlertDialog::new(
                    Some("Could not redeem token"),
                    Some(&state.error),
                );
                error.add_response("done", "Done");
                error.set_close_response("done");
                let window = app.borrow().window.clone();
                error.present(Some(&window));
            }
        });
    } else {
        dialog.add_response("done", "Done");
        dialog.set_close_response("done");
        dialog.set_default_response(Some("done"));
    }
    let window = app.borrow().window.clone();
    dialog.present(Some(&window));
}

fn is_likely_cashu_token(value: &str) -> bool {
    let token = value.trim();
    token.len() > 12
        && token
            .get(..5)
            .is_some_and(|prefix| prefix.eq_ignore_ascii_case("cashu"))
}

fn wallet_withdraw_row(app: &AppRef, parent: &gtk::Box) {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let input = entry(
        "Lightning invoice",
        &app.borrow().drafts.paid_route_withdraw_invoice,
    );
    {
        let app = app.clone();
        input.connect_changed(move |entry| {
            app.borrow_mut().drafts.paid_route_withdraw_invoice = entry.text().to_string();
        });
    }
    let withdraw = icon_text_button("Withdraw", "go-down-symbolic");
    withdraw.set_sensitive(
        !app.borrow()
            .state
            .paid_route_market
            .wallet
            .default_mint
            .trim()
            .is_empty(),
    );
    {
        let app = app.clone();
        withdraw.connect_clicked(move |_| {
            let invoice = {
                let model = app.borrow();
                model.drafts.paid_route_withdraw_invoice.trim().to_string()
            };
            if !invoice.is_empty() {
                dispatch(
                    &app,
                    NativeAppAction::WithdrawPaidRouteWalletLightning {
                        mint_url: None,
                        invoice,
                    },
                );
            }
        });
    }
    row.append(&input);
    row.append(&withdraw);
    parent.append(&row);
}

fn paid_route_mint_row(app: &AppRef, parent: &gtk::Box, mint: &NativePaidRouteWalletMintState) {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    row.set_valign(gtk::Align::Center);
    let text = gtk::Box::new(gtk::Orientation::Vertical, 2);
    text.set_hexpand(true);
    let title = gtk::Label::new(Some(&mint.url));
    title.add_css_class("heading");
    title.set_xalign(0.0);
    text.append(&title);
    if mint.balance_known {
        let status = non_empty_or(
            &mint.balance_text,
            &format_paid_route_msat(mint.balance_msat),
        );
        let status = gtk::Label::new(Some(&status));
        status.add_css_class("caption");
        status.add_css_class("dim-label");
        status.set_xalign(0.0);
        text.append(&status);
    }
    row.append(&text);
    if mint.is_default {
        row.append(&badge("Default", "ok"));
    } else {
        let make_default = icon_text_button("Default", "object-select-symbolic");
        {
            let app = app.clone();
            let url = mint.url.clone();
            make_default.connect_clicked(move |_| {
                dispatch(
                    &app,
                    NativeAppAction::SetPaidRouteDefaultMint { url: url.clone() },
                );
            });
        }
        row.append(&make_default);
    }
    let remove = icon_text_button("Remove", "edit-delete-symbolic");
    {
        let app = app.clone();
        let url = mint.url.clone();
        remove.connect_clicked(move |_| {
            dispatch(
                &app,
                NativeAppAction::RemovePaidRouteWalletMint { url: url.clone() },
            );
        });
    }
    row.append(&remove);
    parent.append(&row);
}
