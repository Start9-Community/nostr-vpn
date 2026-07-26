import { readFileSync } from 'node:fs';

import { expect, test, type APIRequestContext, type Page } from '@playwright/test';

import type { NetworkView, UiState } from '../src/lib/types';

type FixtureMetadata = {
  adminNpub: string;
  joinerNpub: string;
  joinerAlias: string;
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

async function tick(request: APIRequestContext, baseUrl: string): Promise<UiState> {
  const response = await request.post(`${baseUrl}/api/tick`);
  expect(response.ok(), `${baseUrl}/api/tick returned ${response.status()}`).toBeTruthy();
  return (await response.json()) as UiState;
}

function networkByMesh(state: UiState, meshNetworkId: string): NetworkView | undefined {
  return state.networks.find((network) => network.networkId === meshNetworkId);
}

async function driveJoiner(page: Page, request: APIRequestContext) {
  await page.goto(joinerBaseUrl);
  await expect(page).toHaveTitle('Nostr VPN');
  await expect(page.getByRole('button', { name: 'Add Network' })).toBeVisible();

  const before = await tick(request, joinerBaseUrl);
  expect(before.ownNpub).toBe(metadata.joinerNpub);
  expect(before.networks).toHaveLength(0);

  await page.getByRole('button', { name: 'Add Network' }).click();
  await page.getByRole('button', { name: 'Join Network', exact: true }).click();
  const form = page.locator('form.modal-section').filter({
    has: page.getByRole('heading', { name: 'Manual join' }),
  });
  await form.getByLabel('Admin Device ID').fill(metadata.adminNpub);
  await form.getByLabel('Network ID').fill(metadata.meshNetworkId);
  await form.getByRole('button', { name: 'Add manually' }).click();
  await expect(page.getByRole('dialog', { name: 'Add Network' })).toBeHidden();

  await expect
    .poll(async () => {
      const state = await tick(request, joinerBaseUrl);
      const network = networkByMesh(state, metadata.meshNetworkId);
      return {
        ownNpub: state.ownNpub,
        active: network?.enabled ?? false,
        adminNpub: network?.joinRequestAdminNpub ?? '',
        adminInRoster:
          network?.participants.some(
            (participant) =>
              participant.npub === metadata.adminNpub && participant.isAdmin,
          ) ?? false,
      };
    })
    .toEqual({
      ownNpub: metadata.joinerNpub,
      active: true,
      adminNpub: metadata.adminNpub,
      adminInRoster: true,
    });
}

async function driveAdmin(page: Page, request: APIRequestContext) {
  await page.goto(adminBaseUrl);
  await expect(page).toHaveTitle('Nostr VPN');

  const before = await tick(request, adminBaseUrl);
  expect(before.ownNpub).toBe(metadata.adminNpub);
  expect(networkByMesh(before, metadata.meshNetworkId)?.id).toBe(metadata.networkEntryId);

  await page.getByRole('button', { name: 'Add Device' }).click();
  const form = page.locator('form.modal-section').filter({
    has: page.getByRole('heading', { name: 'Add by Device ID' }),
  });
  await form.getByLabel('Device ID').fill(metadata.joinerNpub);
  await form.getByLabel('Name').fill(metadata.joinerAlias);
  await form.getByRole('button', { name: 'Add', exact: true }).click();
  await expect(page.getByRole('dialog', { name: 'Add Device' })).toBeHidden();

  await expect
    .poll(async () => {
      const state = await tick(request, adminBaseUrl);
      const participant = networkByMesh(state, metadata.meshNetworkId)?.participants.find(
        (candidate) => candidate.npub === metadata.joinerNpub,
      );
      return {
        ownNpub: state.ownNpub,
        participantNpub: participant?.npub ?? '',
        alias: participant?.magicDnsAlias ?? '',
      };
    })
    .toEqual({
      ownNpub: metadata.adminNpub,
      participantNpub: metadata.joinerNpub,
      alias: 'desktop-ui-joiner',
    });
}

test('shipped web/StartOS controls complete both production manual-join roles', async ({
  page,
  request,
}) => {
  expect(metadata.transportMode).toBe('direct');
  expect(metadata.direction).toMatch(/^(node-a-admin|node-b-admin)$/);
  expect(metadata.adminNpub).not.toBe(metadata.joinerNpub);

  await driveJoiner(page, request);
  await driveAdmin(page, request);

  await expect(page.locator('.notice-row.error')).toHaveCount(0);
});
