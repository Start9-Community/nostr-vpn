use nostr_vpn_core::config::FiatCurrency;

use crate::native_state::NativePaidRouteWalletState;

#[derive(Clone, Debug)]
pub struct ExchangeRateSnapshot {
    pub currency: FiatCurrency,
}

#[derive(Clone, Debug)]
pub struct ExchangeRateService {
    currency: FiatCurrency,
}

impl ExchangeRateService {
    #[must_use]
    pub fn for_currency(currency: FiatCurrency) -> Self {
        Self { currency }
    }

    #[must_use]
    pub const fn refresh_if_due(&self) -> bool {
        let _ = self.currency;
        false
    }

    #[must_use]
    pub const fn snapshot(&self) -> ExchangeRateSnapshot {
        ExchangeRateSnapshot {
            currency: self.currency,
        }
    }
}

pub(crate) fn apply_exchange_rate(
    wallet: &mut NativePaidRouteWalletState,
    snapshot: &ExchangeRateSnapshot,
) {
    wallet.fiat_currency = snapshot.currency.as_str().to_string();
    wallet.exchange_rate_status = "Unavailable".to_string();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disabled_service_never_starts_a_background_refresh() {
        let service = ExchangeRateService::for_currency(FiatCurrency::Usd);

        assert!(!service.refresh_if_due());
        assert_eq!(service.snapshot().currency, FiatCurrency::Usd);
    }
}
