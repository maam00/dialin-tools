// USB interface claim policy. No USB import: tests and offline commands can load this without native bindings.
import { spawnSync } from "node:child_process";
import { setTimeout as pause } from "node:timers/promises";

const MAC_DAEMON = "ptpcamerad";
const exclusiveAccess = (error: unknown) => /exclusive access|0xe00002c5|LIBUSB_ERROR_ACCESS|LIBUSB_ERROR_BUSY/i.test(String((error as Error)?.message ?? error));

/** Accurate guidance for a refused USB claim. macOS 27 evidence: `killall` returned 0 but did not stop ptpcamerad. */
export function claimFailureMessage(error: unknown, platform: string = process.platform, released = false, triedRelease = released): string {
  const detail = String((error as Error)?.message ?? error);
  if (platform !== "darwin") return `Couldn't claim the camera (${detail}). Close other camera or photo-import programs and check USB permissions, then retry.`;
  if (released) return `Couldn't claim the camera (${detail}) even after stopping ${MAC_DAEMON}. Quit Photos and Image Capture, reconnect the camera, then retry.`;
  // The opt-in ran but found nothing to stop: another program, not the daemon, is the likely holder.
  if (triedRelease) return `Couldn't claim the camera (${detail}). No ${MAC_DAEMON} process of yours was running, so nothing was stopped; another program probably holds the camera. Quit Photos, Image Capture and other camera apps, reconnect the camera, then retry.`;
  return `Couldn't claim the camera (${detail}). macOS's camera daemon (${MAC_DAEMON}) usually holds it. Quit Photos and Image Capture. `
    + `\`killall ${MAC_DAEMON}\` did not release it on macOS 27; \`kill -9 $(pgrep -x -U "$(id -u)" ${MAC_DAEMON})\` immediately before the command did. `
    + `launchd restarts the daemon and it takes the camera again, so repeat that before every command, or add --release-macos-camera-daemon to let this command do it.`;
}

/** SIGKILL the current user's ptpcamerad (exact name). launchd restarts it; any import it was serving is interrupted. */
export function stopMacCameraDaemon(): number[] {
  const uid = process.getuid?.();
  if (process.platform !== "darwin" || uid === undefined) return [];
  const found = spawnSync("/usr/bin/pgrep", ["-x", "-U", String(uid), MAC_DAEMON], { encoding: "utf8", timeout: 2000 });
  const pids = (found.stdout ?? "").split(/\s+/).filter(Boolean).map(Number).filter((pid) => Number.isInteger(pid) && pid > 1 && pid !== process.pid);
  for (const pid of pids) { try { process.kill(pid, "SIGKILL"); } catch { /* already gone */ } }
  return pids;
}

export type ClaimOptions = { releaseMacCameraDaemon?: boolean; platform?: string; release?: () => number[];
  attempts?: number; delayMs?: number; onRelease?: (pids: number[]) => void };

/** Claim once. Only with the explicit macOS opt-in, after an exclusive-access refusal, stop ptpcamerad and retry for about 1 s. */
export async function claimCamera(claim: (retry: boolean) => Promise<void>, options: ClaimOptions = {}): Promise<{ releasedPids: number[] }> {
  const platform = options.platform ?? process.platform;
  try { await claim(false); return { releasedPids: [] }; } catch (error) {
    if (!options.releaseMacCameraDaemon || platform !== "darwin" || !exclusiveAccess(error)) throw new Error(claimFailureMessage(error, platform));
    const releasedPids: number[] = [];
    let last: unknown = error;
    for (let attempt = 0; attempt < (options.attempts ?? 5); attempt++) {
      const pids = (options.release ?? stopMacCameraDaemon)();
      releasedPids.push(...pids);
      if (pids.length) options.onRelease?.(pids);
      await pause(options.delayMs ?? 200);
      try { await claim(true); return { releasedPids }; } catch (retryError) { last = retryError; if (!exclusiveAccess(retryError)) break; }
    }
    throw new Error(claimFailureMessage(last, platform, releasedPids.length > 0, true));
  }
}
