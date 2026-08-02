import { readFileSync } from 'node:fs';

import { expect, test, type APIRequestContext } from '@playwright/test';

import type { UiState } from '../src/lib/types';

type FixtureMetadata = {
  adminNpub: string;
  joinerNpub: string;
  meshNetworkId: string;
  networkEntryId: string;
  direction: string;
  transportMode: string;
};

test.describe.configure({ mode: 'serial', timeout: 45_000 });

function requiredEnv(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`${name} is required`);
  }
  return value.replace(/\/+$/, '');
}

const adminBaseUrl = requiredEnv('NVPN_WEB_STARTOS_JOIN_ADMIN_BASE_URL');
const joinerBaseUrl = requiredEnv('NVPN_WEB_STARTOS_JOIN_JOINER_BASE_URL');
const metadataPath = requiredEnv('NVPN_WEB_STARTOS_JOIN_RESULT');
const metadata = JSON.parse(readFileSync(metadataPath, 'utf8')) as FixtureMetadata;

async function postState(
  request: APIRequestContext,
  baseUrl: string,
  path: string,
  data?: Record<string, unknown>,
): Promise<UiState> {
  const response = await request.post(`${baseUrl}${path}`, { data });
  if (!response.ok()) {
    throw new Error(`${baseUrl}${path} returned ${response.status()}: ${await response.text()}`);
  }
  return (await response.json()) as UiState;
}

test('split web and daemon complete signed LAN-discovered approval', async ({ request }) => {
  expect(metadata.transportMode).toBe('direct');
  expect(metadata.direction).toMatch(/^(node-a-admin|node-b-admin)$/);
  expect(metadata.adminNpub).not.toBe(metadata.joinerNpub);

  let joinerBroadcasting = false;
  let adminDiscovering = false;
  try {
    const joinerBefore = await postState(request, joinerBaseUrl, '/api/tick');
    expect(joinerBefore.ownNpub).toBe(metadata.joinerNpub);
    expect(joinerBefore.networks).toHaveLength(0);

    let joinerState = await postState(
      request,
      joinerBaseUrl,
      '/api/start_join_request_broadcast',
    );
    joinerBroadcasting = true;
    expect(joinerState.joinRequestBroadcastActive).toBeTruthy();
    expect(joinerState.joinRequestQrCodeOrLink).toMatch(/^nvpn:\/\/join-request\//);

    let adminState = await postState(request, adminBaseUrl, '/api/connect_vpn');
    expect(adminState.vpnEnabled).toBeTruthy();
    adminState = await postState(request, adminBaseUrl, '/api/start_nearby_discovery');
    adminDiscovering = true;
    expect(adminState.nearbyDiscoveryActive).toBeTruthy();

    let discoveredNetworkId = '';
    await expect
      .poll(
        async () => {
          const state = await postState(request, adminBaseUrl, '/api/tick');
          const peer = state.lanPeers.find((candidate) => candidate.npub === metadata.joinerNpub);
          discoveredNetworkId = peer?.networkId ?? '';
          return Boolean(peer);
        },
        { timeout: 15_000 },
      )
      .toBeTruthy();

    adminState = await postState(request, adminBaseUrl, '/api/import_nearby_peer', {
      npub: metadata.joinerNpub,
      networkId: discoveredNetworkId,
    });
    expect(
      adminState.networks
        .find((network) => network.id === metadata.networkEntryId)
        ?.participants.find((participant) => participant.npub === metadata.joinerNpub)
        ?.magicDnsAlias,
    ).toBe(joinerBefore.nodeName);
  } finally {
    if (adminDiscovering) {
      const state = await postState(request, adminBaseUrl, '/api/stop_nearby_discovery');
      expect(state.nearbyDiscoveryActive).toBeFalsy();
    }
    if (joinerBroadcasting) {
      const state = await postState(request, joinerBaseUrl, '/api/stop_join_request_broadcast');
      expect(state.joinRequestBroadcastActive).toBeFalsy();
    }
  }
});
