// PTP over USB for Node (Mac for testing, Linux on the gadget), using node-usb's WebUSB shim.
// Mirrors FilmKit's WebUSB transport, minus the browser device picker.
import { WebUSB } from "usb";
import { claimCamera } from "./claim.js";
import { containerLength, packContainer, type PTPContainerData, unpackContainer } from "./vendor/container.js";
import { ContainerType } from "./vendor/constants.js";

type UsbDevice = Awaited<ReturnType<WebUSB["getDevices"]>>[number];

export const FUJI_VENDOR_ID = 0x04cb;
const CHUNK = 512 * 1024;
const TIMEOUT_MS = 5000;

export class UsbPtp {
  /** Explicit opt-in only: may SIGKILL the current user's macOS ptpcamerad after a refused claim. */
  releaseMacCameraDaemon = false;
  onMacCameraDaemonReleased?: (pids: number[]) => void;
  private device: UsbDevice | null = null;
  private epIn = 0;
  private epOut = 0;
  private txn = 0;

  get productName(): string {
    return this.device?.productName ?? "unknown";
  }

  async open(): Promise<void> {
    const webusb = new WebUSB({ allowAllDevices: true });
    const devices = await webusb.getDevices();
    const dev = devices.find((d) => d.vendorId === FUJI_VENDOR_ID);
    if (!dev) {
      throw new Error(
        "No Fujifilm camera on USB. Turn it on, set CONNECTION MODE to USB RAW CONV./BACKUP RESTORE, and plug it in.",
      );
    }
    await dev.open();
    if (!dev.configuration) await dev.selectConfiguration(1);
    if (process.platform === "linux") await dev.detachKernelDriver(0).catch(() => {});
    await claimCamera(async (retry) => {
      if (retry) { await dev.close().catch(() => {}); await dev.open(); if (!dev.configuration) await dev.selectConfiguration(1); }
      await dev.claimInterface(0);
    }, { releaseMacCameraDaemon: this.releaseMacCameraDaemon, onRelease: this.onMacCameraDaemonReleased });
    const alt = dev.configuration!.interfaces[0].alternate;
    for (const ep of alt.endpoints) {
      if (ep.type !== "bulk") continue;
      if (ep.direction === "out") this.epOut = ep.endpointNumber;
      if (ep.direction === "in") this.epIn = ep.endpointNumber;
    }
    if (!this.epIn || !this.epOut) throw new Error("Camera has no bulk endpoints on interface 0");
    this.device = dev;
  }

  async close(): Promise<void> {
    if (!this.device) return;
    try {
      await this.device.releaseInterface(0);
    } catch { /* already gone */ }
    await this.device.close().catch(() => {});
    this.device = null;
  }

  /** Next command goes out as transaction 0 (required for OpenSession). */
  resetTransactions(): void {
    this.txn = -1;
  }

  private nextTxn(): number {
    this.txn = (this.txn + 1) >>> 0;
    return this.txn;
  }

  private async send(c: PTPContainerData): Promise<void> {
    const bytes = packContainer(c);
    for (let off = 0; off < bytes.length; off += CHUNK) {
      await this.device!.nativeTransferOut(this.epOut, TIMEOUT_MS, bytes.slice(off, off + CHUNK));
    }
  }

  private async read(): Promise<Uint8Array> {
    const data = await this.device!.nativeTransferIn(this.epIn, TIMEOUT_MS, CHUNK);
    if (!data) throw new Error("USB read returned nothing");
    return data;
  }

  private async recv(): Promise<PTPContainerData> {
    let data = await this.read();
    const total = containerLength(data);
    while (data.length < total) {
      const more = await this.read();
      const merged = new Uint8Array(data.length + more.length);
      merged.set(data);
      merged.set(more, data.length);
      data = merged;
    }
    return unpackContainer(data);
  }

  /** Command with an optional DATA phase from the camera. */
  async command(op: number, params: number[] = []): Promise<{ code: number; params: number[]; data: Uint8Array }> {
    const transactionId = this.nextTxn();
    await this.send({ type: ContainerType.Command, code: op, transactionId, params, data: new Uint8Array(0) });
    let resp = await this.recv();
    let data: Uint8Array = new Uint8Array(0);
    if (resp.type === ContainerType.Data) {
      data = resp.data;
      resp = await this.recv();
    }
    if (resp.type !== ContainerType.Response) throw new Error(`Expected RESPONSE, got type ${resp.type}`);
    return { code: resp.code, params: resp.params, data };
  }

  /** Command followed by a DATA phase from us (e.g. SetDevicePropValue). */
  async commandWithData(op: number, params: number[], payload: Uint8Array): Promise<{ code: number }> {
    const transactionId = this.nextTxn();
    await this.send({ type: ContainerType.Command, code: op, transactionId, params, data: new Uint8Array(0) });
    await this.send({ type: ContainerType.Data, code: op, transactionId, params: [], data: new Uint8Array(payload) });
    const resp = await this.recv();
    if (resp.type !== ContainerType.Response) throw new Error(`Expected RESPONSE, got type ${resp.type}`);
    return { code: resp.code };
  }
}
