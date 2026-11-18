<script lang="ts">
  import { createEventDispatcher, onDestroy } from 'svelte';

  type ButtonVariant = 'small' | 'secondary';

  export let value = '';
  export let label = 'Value';
  export let text = '';
  export let disabled = false;
  export let variant: ButtonVariant = 'small';

  const dispatch = createEventDispatcher<{ copied: { label: string; value: string } }>();

  let copied = false;
  let failed = false;
  let copying = false;
  let attempted = { label: '', value: '' };
  let copiedTimer: number | undefined;

  $: if (attempted.value !== value || attempted.label !== label) {
    copied = false;
    failed = false;
  }

  onDestroy(() => {
    if (copiedTimer) {
      window.clearTimeout(copiedTimer);
    }
  });

  async function writeClipboard(text: string) {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch {
      const focused = document.activeElement;
      const area = document.createElement('textarea');
      area.value = text;
      area.style.position = 'fixed';
      area.style.opacity = '0';
      try {
        document.body.append(area);
        area.select();
        return document.execCommand('copy');
      } catch {
        return false;
      } finally {
        area.remove();
        if (focused instanceof HTMLElement) focused.focus();
      }
    }
  }

  async function copy() {
    if (disabled || !value || copying) {
      return;
    }

    const current = { label, value };
    attempted = current;
    copying = true;
    copied = false;
    failed = false;
    if (copiedTimer) {
      window.clearTimeout(copiedTimer);
    }
    const success = await writeClipboard(current.value);
    copying = false;
    if (current.value !== value || current.label !== label) return;
    copied = success;
    failed = !success;
    if (!success) return;
    dispatch('copied', current);

    copiedTimer = window.setTimeout(() => {
      copied = false;
      copiedTimer = undefined;
    }, 2000);
  }
</script>

<button
  type="button"
  class="copy-button {variant}"
  class:with-text={Boolean(text) || failed}
  class:copied
  disabled={disabled || !value}
  aria-disabled={disabled || !value || copying}
  aria-busy={copying}
  aria-label={failed ? `Copy ${label} failed. Try again` : copied ? `${label} copied` : `Copy ${label}`}
  title={failed ? 'Copy failed. Try again' : copied ? 'Copied' : `Copy ${label}`}
  on:click={copy}
>
  {#if copied}
    <svg aria-hidden="true" viewBox="0 0 16 16" focusable="false">
      <path d="M6.7 11.4 3.3 8l1.1-1.1 2.3 2.3 4.9-4.9L12.7 5z" />
    </svg>
  {:else}
    <svg aria-hidden="true" viewBox="0 0 16 16" focusable="false">
      <path d="M5 2.5h7.5V10H11V4H5z" />
      <path d="M3.5 5H10v8.5H3.5z" />
    </svg>
  {/if}
  {#if failed}
    <span role="status">Copy failed. Retry</span>
  {:else if text}
    <span>{text}</span>
  {/if}
</button>

<style>
  .copy-button {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    flex: 0 0 auto;
    gap: 7px;
    border: 1px solid var(--border, rgba(255, 255, 255, 0.12));
    border-radius: 8px;
    color: var(--text-primary, #f5f5f7);
    background: var(--control, #2c2c2e);
    font-weight: 700;
  }

  .copy-button.small {
    width: 34px;
    min-height: 34px;
  }

  .copy-button.secondary {
    width: 40px;
    min-height: 40px;
  }

  .copy-button.with-text {
    width: auto;
    min-width: 0;
    padding: 0 12px;
  }

  .copy-button:not(:disabled):hover {
    background: var(--control-hover, #363638);
  }

  .copy-button.copied {
    border-color: transparent;
    color: var(--ok, #30d158);
    background: var(--ok-soft, rgba(48, 209, 88, 0.16));
  }

  .copy-button svg {
    width: 16px;
    height: 16px;
    fill: currentColor;
  }
</style>
