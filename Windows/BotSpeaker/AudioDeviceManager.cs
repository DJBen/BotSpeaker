using NAudio.CoreAudioApi;

namespace BotSpeaker;

public sealed record AudioDevice(string Id, string Name)
{
    /// <summary>
    /// True for the render side of a virtual audio cable (the device BotSpeaker should
    /// play into so that a meeting app can pick up its capture side as a microphone).
    /// VB-Audio Virtual Cable exposes "CABLE Input" as the render endpoint.
    /// </summary>
    public bool IsVirtualCable =>
        Name.Contains("CABLE", StringComparison.OrdinalIgnoreCase) ||
        Name.Contains("VB-Audio", StringComparison.OrdinalIgnoreCase) ||
        Name.Contains("Virtual", StringComparison.OrdinalIgnoreCase);
}

public sealed class AudioDeviceManager
{
    public List<AudioDevice> OutputDevices { get; private set; } = [];
    public List<AudioDevice> InputDevices { get; private set; } = [];

    public event Action? DevicesChanged;

    public void Refresh()
    {
        using var enumerator = new MMDeviceEnumerator();
        OutputDevices = Enumerate(enumerator, DataFlow.Render)
            .OrderByDescending(d => d.IsVirtualCable)
            .ThenBy(d => d.Name, StringComparer.CurrentCultureIgnoreCase)
            .ToList();
        InputDevices = Enumerate(enumerator, DataFlow.Capture)
            .OrderBy(d => d.IsVirtualCable)
            .ThenBy(d => d.Name, StringComparer.CurrentCultureIgnoreCase)
            .ToList();
        DevicesChanged?.Invoke();
    }

    private static List<AudioDevice> Enumerate(MMDeviceEnumerator enumerator, DataFlow flow)
    {
        var devices = new List<AudioDevice>();
        foreach (var device in enumerator.EnumerateAudioEndPoints(flow, DeviceState.Active))
        {
            try
            {
                devices.Add(new AudioDevice(device.ID, device.FriendlyName));
            }
            finally
            {
                device.Dispose();
            }
        }
        return devices;
    }

    public static MMDevice? Device(string id)
    {
        if (string.IsNullOrEmpty(id)) return null;
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            return enumerator.GetDevice(id);
        }
        catch (Exception)
        {
            return null;
        }
    }

    public static string? DefaultInputDeviceId()
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            using var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console);
            return device.ID;
        }
        catch (Exception)
        {
            return null;
        }
    }
}
