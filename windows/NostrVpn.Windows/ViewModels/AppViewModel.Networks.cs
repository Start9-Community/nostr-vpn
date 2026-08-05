using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32;
using NostrVpn.Windows.Core;
using NostrVpn.Windows.Services;

namespace NostrVpn.Windows.ViewModels;

public sealed partial class AppViewModel
{
    public Task RemoveParticipantAsync(NativeParticipantState participant)
    {
        var network = ActiveNetwork;
        if (network?.LocalIsAdmin != true || participant.IsSelf)
        {
            return Task.CompletedTask;
        }
        return DispatchAsync(NativeActions.RemoveParticipant(network.Id, participant.Npub), "Removing device");
    }

    public Task ToggleAdminAsync(NativeParticipantState participant)
    {
        var network = ActiveNetwork;
        if (network?.LocalIsAdmin != true || participant.IsSelf)
        {
            return Task.CompletedTask;
        }
        return DispatchAsync(
            participant.IsAdmin
                ? NativeActions.RemoveAdmin(network.Id, participant.Npub)
                : NativeActions.AddAdmin(network.Id, participant.Npub),
            participant.IsAdmin ? "Removing admin" : "Adding admin");
    }

    public Task ActivateNetworkAsync(string networkId)
    {
        return DispatchAsync(NativeActions.SetNetworkEnabled(networkId, true), "Activating network");
    }

    public void SelectShownNetwork(string networkId)
    {
        if (_shownNetworkId == networkId)
        {
            return;
        }
        _shownNetworkId = networkId;
        NormalizeSelectedParticipant(State);
        SyncDrafts(State);
        RaiseDerivedStateChanged();
        CommandManager.InvalidateRequerySuggested();
    }

    public Task RemoveNetworkAsync(string networkId)
    {
        return DispatchAsync(NativeActions.RemoveNetwork(networkId), "Deleting network");
    }

    public Task RenameActiveNetworkAsync()
    {
        var network = ActiveNetwork;
        var name = NetworkNameDraft.Trim();
        return network is null || string.IsNullOrWhiteSpace(name)
            ? Task.CompletedTask
            : DispatchAsync(NativeActions.RenameNetwork(network.Id, name), "Renaming network");
    }

    public Task SaveActiveNetworkMeshIdAsync()
    {
        var network = ActiveNetwork;
        var meshId = NormalizeNetworkIdInput(NetworkMeshIdDraft);
        return network is null || string.IsNullOrWhiteSpace(meshId)
            ? Task.CompletedTask
            : DispatchAsync(NativeActions.SetNetworkMeshId(network.Id, meshId), "Saving network ID");
    }

    public Task SetParticipantAliasAsync(NativeParticipantState participant, string alias)
    {
        return ActiveNetwork?.LocalIsAdmin == true
            ? DispatchAsync(NativeActions.SetParticipantAlias(participant.Npub, alias.Trim()), "Saving alias")
            : Task.CompletedTask;
    }

    public Task SetParticipantEndpointHintsAsync(NativeParticipantState participant, string hints)
    {
        if (ActiveNetwork?.LocalIsAdmin != true || participant.IsSelf)
        {
            return Task.CompletedTask;
        }
        var parsed = (hints ?? string.Empty)
            .Split([',', '\n', '\r', '\t', ' '], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Where(value => !string.IsNullOrWhiteSpace(value))
            .Distinct(StringComparer.Ordinal)
            .ToList();
        return DispatchAsync(
            NativeActions.SetParticipantEndpointHints(participant.Npub, parsed),
            "Saving address hints");
    }
}
