fn paid_route_payment_action_title(kind: &str) -> String {
    match kind {
        "send" => "Payment sent".to_string(),
        "receive" => "Payment received".to_string(),
        "apply" => "Payment applied".to_string(),
        "create" | "sign" => "Payment ready".to_string(),
        "open_channel" => "Exit funded".to_string(),
        "close" => "Channel settled".to_string(),
        "stream" => "Payments sent".to_string(),
        "probe" => "Quality checked".to_string(),
        "" => "Payment".to_string(),
        other => paid_route_plain_status(other, "Payment"),
    }
}

fn paid_route_wallet_action_title(kind: &str) -> String {
    match kind {
        "topup" => "Invoice ready".to_string(),
        "receive" => "Token imported".to_string(),
        "send" => "Token ready".to_string(),
        "withdraw" => "Invoice paid".to_string(),
        "refresh" => "Wallet refreshed".to_string(),
        "open_channel" => "Exit funded".to_string(),
        "" => "Wallet updated".to_string(),
        other => paid_route_plain_status(other, "Wallet updated"),
    }
}
