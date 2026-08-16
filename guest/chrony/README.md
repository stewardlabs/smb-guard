# Guest clock — chrony reference configuration

The files in this directory are **not deployed automatically by install.sh.**
System clock policy varies by distribution and getting it wrong is costly. Read
them and apply them yourself.

## Role split

| Layer | Owner | When |
|---|---|---|
| standing authority | chrony (NTP) | continuously while awake |
| resume step | `clockfix` (called over ssh by the host hook) | once, right after wake |
| hypervisor time synchronisation | **off** | — |

A hypervisor's guest time synchronisation and guest NTP **sometimes cannot
coexist.** Parallels' `prltimesync` runs `timedatectl set-ntp 0` every time it
starts, disabling and stopping the guest NTP unit (it leaves its name in the
journal as `Disabling unit`). Mistaking that state for "three layers of defence"
means actually running on a single layer, and then that one dies quietly — a skew
of +76482 seconds (21 hours) arose exactly that way.

Keep the instrumentable one. chrony leaves a full history via `chronyc tracking`
and the journal, whereas hypervisor synchronisation has no log and lets skew
through while showing a green light.

```bash
# For Parallels — once, from the host; stored permanently in the .pvm configuration
prlctl set <VM name> --time-sync off
prlctl list -i <VM name> | grep -i "Time Sync"     # must read (-)
```

Other hypervisors have an equivalent setting (VMware `tools.syncTime`, VirtualBox's
`--timesync-set-start` family, time sync in UTM/QEMU's `qemu-guest-agent`).

> **The stronger remedy is not installing the guest integration tools at all.** The
> setting above is one line, so a tool's auto-update, reinstall or configuration
> restore can revert it, and a reverted state leaves no log, so it stays hidden
> until the next skew. On a headless development guest everything else the tools
> provide (clipboard, display, shared folders, automatic host hosts registration)
> is either unnecessary or something this design does not use. For the rationale
> and the removal procedure see 'The stronger remedy' under Layer 1 in
> [failure-model.md](../../docs/failure-model.md).

## Files

### `makestep.conf`

Put it at the end of `/etc/chrony/chrony.conf` or into `/etc/chrony/conf.d/`.

Allows stepping without a count limit, because chrony has to recover a large error
on its own even when `clockfix` fails after resume — the default policy allows a
step only a few times right after startup and closes the gap by slewing thereafter,
which effectively cannot recover an error of thousands of seconds.

### `local-pool.conf.example`

A nearby NTP source. When the distribution's default pool is geographically distant,
RTT and reachability suffer (with a configuration depending on a single source in
the UK, being left offline for 1 hour 11 minutes was measured).

`maxpoll 6` (64 seconds) is **the worst-case recovery time of the fallback when
clockfix has failed**. With the default of 1024 seconds the clock can stay wrong for
17 minutes after a wake.

## Clearing a contaminated drift file

`chronyd` **rewrites** the drift file when it exits. So finishing with
`stop -> rm -> start` brings the contaminated value back — there was a case where,
after an `rm` and a reboot, the booting instance loaded the previous value
(-27905 ppm) unchanged.

**The cleanup is one unit of work up to and including confirming convergence.** A
reboot before convergence propagates the contamination one more generation.

```bash
sudo systemctl stop chrony
sudo rm -f /var/lib/chrony/chrony.drift
sudo systemctl start chrony
sleep 20 && chronyc tracking      # watch until Frequency converges to single-digit ppm
```

## Healthy indicators

```bash
chronyc tracking
#   System time : milliseconds
#   Frequency   : single-digit ppm
journalctl -u chrony | grep -i stepped    # must be 0 occurrences while awake
```

A `stepped` entry while awake means `clockfix` was late — a resume step does not
appear in chrony's log (chronyd detects an external step and merely resets its
history).
