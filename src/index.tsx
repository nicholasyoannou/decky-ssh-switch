import { callable, definePlugin } from "@decky/api";
import { ButtonItem, ConfirmModal, PanelSection, PanelSectionRow, TextField, ToggleField, showModal } from "@decky/ui";
import { useEffect, useRef, useState } from "react";

interface Status {
  username: string;
  running: boolean;
  startup: boolean;
  active_state: string;
  boot_state: string;
  masked: boolean;
  transitioning: boolean;
}

const getStatus = callable<[], Status>("get_status");
interface ConnectionInfo {
  username: string;
  hostname: string;
  addresses: { address: string; interface: string }[];
  ports: number[];
  folders: { label: string; path: string }[];
  fingerprint: string;
}
const getConnectionInfo = callable<[], ConnectionInfo>("get_connection_info");
const setEnabled = callable<[boolean], Status>("set_enabled");
const setStartup = callable<[boolean], Status>("set_startup");
const verifyCurrentPassword = callable<[string], { verification: string | null; password_available: boolean }>("verify_current_password");
const setPassword = callable<[string, string], { username: string; changed: boolean; verification_required?: boolean }>("set_password");
// Current Steam forwards native input props, although Decky's type declaration
// only lists the legacy bIsPassword flag. Supply both for runtime compatibility.
const passwordInputProps = { type: "password", autoComplete: "new-password" } as const;

function sameStatus(previous: Status | null, next: Status) {
  return previous !== null && (Object.keys(next) as (keyof Status)[])
    .every((key) => previous[key] === next[key]);
}

function ConnectionDialog({ closeModal }: { closeModal?: () => void }) {
  const [info, setInfo] = useState<ConnectionInfo | null>(null);
  const [error, setError] = useState("");
  useEffect(() => {
    let active = true;
    void getConnectionInfo().then(
      (result) => { if (active) setInfo(result); },
      () => { if (active) setError("Could not load connection details. Enable SSH and check your network, then reopen this dialog."); },
    );
    return () => { active = false; };
  }, []);
  return <ConfirmModal
    strTitle="Connect from computer"
    strDescription="Run the mounting script on a computer on the same network."
    strOKButtonText="Close"
    bAlertDialog
    onOK={closeModal}
    onCancel={closeModal}
  >
    <div style={{ fontSize: 14, lineHeight: 1.4, overflowWrap: "anywhere" }}>
      {error ? <p role="alert">{error}</p> : !info ? <p role="status">Loading connection details…</p> : <>
        <p style={{ margin: "8px 0" }}><strong>Address:</strong> {info.addresses.length
          ? info.addresses.map((item) => `${item.address} (${item.interface})`).join(", ")
          : `${info.hostname} — no IPv4 address found; check your network.`}<br />
          <strong>Port:</strong> {info.ports.join(", ")} <span style={{ marginLeft: 16 }}><strong>Username:</strong> {info.username}</span></p>
        <p style={{ margin: "8px 0" }}><strong>Remote folder:</strong><br />{info.folders.map((folder) => <span key={folder.path}>{folder.label}: <code>{folder.path}</code><br /></span>)}</p>
        <p style={{ margin: "8px 0" }}><strong>SSH fingerprint (Ed25519):</strong><br /><code style={{ fontSize: 12 }}>{info.fingerprint}</code></p>
        <p style={{ margin: "8px 0" }}>Compare this fingerprint when prompted, then enter your Deck password.</p>
      </>}
    </div>
  </ConfirmModal>;
}

interface PasswordDialogProps {
  username: string;
  onChanged: (username: string) => void;
  closeModal?: () => void;
}

function PasswordDialog({ username, onChanged, closeModal }: PasswordDialogProps) {
  const [verification, setVerification] = useState<string | null>(null);
  const [password, updatePassword] = useState("");
  const [confirmation, updateConfirmation] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const inFlight = useRef(false);
  const mounted = useRef(false);
  const verifying = verification === null;
  const invalid = verifying ? password.length === 0 : password.trim().length === 0 || password !== confirmation;
  const mismatch = !verifying && confirmation.length > 0 && password !== confirmation;

  useEffect(() => {
    mounted.current = true;
    return () => { mounted.current = false; };
  }, []);

  function dismiss() {
    if (!inFlight.current) closeModal?.();
  }

  async function submitPassword() {
    if (inFlight.current || invalid) return;
    inFlight.current = true;
    setBusy(true);
    setError("");
    // Clear both fields immediately, including when the system rejects a change.
    const value = password;
    updatePassword("");
    updateConfirmation("");
    try {
      if (verification === null) {
        const result = await verifyCurrentPassword(value);
        if (mounted.current) {
          if (result.verification) setVerification(result.verification);
          else setError(result.password_available
            ? "The current password is incorrect. Try again."
            : "This account has no usable password. Open a terminal in Desktop Mode and run passwd to set one first.");
        }
        return;
      }
      const result = await setPassword(value, verification);
      if (mounted.current && result.verification_required) {
        setVerification(null);
        setError("Verify your current password again before making this change.");
        return;
      }
      if (!result.changed) throw new Error("Password change was not confirmed.");
      if (mounted.current) {
        onChanged(result.username);
        closeModal?.();
      }
    } catch {
      // Do not reflect an RPC exception that could include its request payload.
      if (mounted.current) {
        setVerification(null);
        setError(verifying
          ? "The system could not verify the password. Try again."
          : "The system could not update the password. If the request timed out, check which password works before retrying.");
      }
    } finally {
      inFlight.current = false;
      if (mounted.current) setBusy(false);
    }
  }

  return (
    <ConfirmModal
      strTitle={verifying ? "Verify current password" : "Change password"}
      strDescription={verifying
        ? <>Enter the current Linux password for <strong>{username}</strong> to continue.</>
        : <>Changes the Linux password for <strong>{username}</strong>, used by SSH and sudo.</>}
      strOKButtonText={busy ? (verifying ? "Verifying…" : "Saving…") : verifying ? "Continue" : "Save password"}
      strCancelButtonText="Cancel"
      bOKDisabled={busy || invalid}
      bCancelDisabled={busy}
      bDisableBackgroundDismiss={busy}
      bHideCloseIcon={busy}
      onOK={submitPassword}
      onCancel={dismiss}
    >
      {/* Keep closeModal on this component so Steam only closes after a successful save. */}
      <div style={{ marginTop: 16 }}>
        <TextField {...{ ...passwordInputProps, autoComplete: verifying ? "current-password" : "new-password" }} key={verifying ? "current" : "new"} label={verifying ? "Current password" : "New password"} bIsPassword bShowCopyAction={false} value={password} disabled={busy} onChange={(event) => updatePassword(event.target.value)} />
      </div>
      {!verifying && <div style={{ marginTop: 16 }}>
        <TextField {...passwordInputProps} label="Confirm password" bIsPassword bShowCopyAction={false} value={confirmation} disabled={busy} onChange={(event) => updateConfirmation(event.target.value)} />
      </div>}
      {(busy || error || mismatch) && <div role={error || mismatch ? "alert" : "status"} style={{ fontSize: 14, lineHeight: 1.5, marginTop: 16 }}>
        {busy ? (verifying ? "Verifying password…" : "Updating password…") : error || "The passwords do not match."}
      </div>}
    </ConfirmModal>
  );
}

function Content() {
  const [status, setStatus] = useState<Status | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [statusError, setStatusError] = useState("");
  const [message, setMessage] = useState("");
  const inFlight = useRef(false);
  const revision = useRef(0);
  const mounted = useRef(false);

  useEffect(() => {
    let active = true;
    let reading = false;
    mounted.current = true;
    async function refresh() {
      if (inFlight.current || reading) return;
      reading = true;
      const startedAtRevision = revision.current;
      try {
        const next = await getStatus();
        if (active && revision.current === startedAtRevision) {
          setStatus((previous) => sameStatus(previous, next) ? previous : next);
          setStatusError("");
        }
      } catch (reason) {
        if (active && revision.current === startedAtRevision) {
          // Retain the last switch positions, but disable them until status recovers.
          setStatusError(reason instanceof Error ? reason.message : String(reason));
        }
      } finally {
        reading = false;
      }
    }
    void refresh();
    const timer = window.setInterval(() => void refresh(), 5000);
    return () => {
      active = false;
      mounted.current = false;
      window.clearInterval(timer);
    };
  }, []);

  async function changeSwitch(kind: "running" | "startup", enabled: boolean) {
    if (inFlight.current) return;
    inFlight.current = true;
    // An earlier background read must not overwrite the result of this action.
    // The backend serializes service requests; a pending read never drops a click.
    revision.current += 1;
    setBusy(true);
    setError("");
    setMessage("");
    try {
      const next = await (kind === "running" ? setEnabled(enabled) : setStartup(enabled));
      if (mounted.current) {
        setStatus(next);
        setStatusError("");
      }
    } catch (reason) {
      if (mounted.current) {
        setError(reason instanceof Error ? reason.message : String(reason));
        // A failed command may have partially changed system state. Keep the
        // error visible, but re-read systemd instead of showing a stale toggle.
        try {
          const next = await getStatus();
          if (mounted.current) {
            setStatus(next);
            setStatusError("");
          }
        } catch { if (mounted.current) setStatus(null); }
      }
    } finally {
      inFlight.current = false;
      if (mounted.current) setBusy(false);
    }
  }

  function openPasswordDialog() {
    setError("");
    setMessage("");
    showModal(<PasswordDialog
      username={status?.username ?? "your Deck account"}
      onChanged={(username) => {
        if (mounted.current) setMessage(`Password updated for ${username}.`);
      }}
    />);
  }

  const loading = !status && !statusError;
  const disabled = busy || !status || !!statusError || status.transitioning;
  return (
    <>
      <PanelSection title="SETTINGS">
        <PanelSectionRow>
          <ToggleField
            label="SSH enabled"
            description={statusError ? "SSH status is unavailable." : status ? (status.transitioning ? "SSH is changing state…" : status.masked ? "SSH is masked in system settings." : status.running ? "Remote connections are on." : "Remote connections are off.") : "Checking SSH status…"}
            checked={status?.running ?? false}
            disabled={disabled || (status?.masked && !status.running)}
            onChange={(enabled) => void changeSwitch("running", enabled)}
          />
        </PanelSectionRow>
        <PanelSectionRow>
          <ToggleField
            label="Start at boot"
            description="Start SSH when the Deck turns on. This does not change whether SSH is running now."
            checked={status?.startup ?? false}
            disabled={disabled || (status?.masked && !status.startup)}
            onChange={(enabled) => void changeSwitch("startup", enabled)}
          />
        </PanelSectionRow>
        <PanelSectionRow>
          <ButtonItem layout="below" disabled={busy || loading} onClick={openPasswordDialog}>Change password</ButtonItem>
        </PanelSectionRow>
        <PanelSectionRow>
          <ButtonItem layout="below" disabled={busy || loading} onClick={() => showModal(<ConnectionDialog />)}>Connect from computer</ButtonItem>
        </PanelSectionRow>
        {status?.active_state === "failed" && <PanelSectionRow><div role="status">SSH failed to start. Check its service status in Desktop Mode.</div></PanelSectionRow>}
      </PanelSection>
      {(error || statusError || message || busy) && <PanelSection><PanelSectionRow>
        <div role={error || statusError ? "alert" : "status"} style={{ fontSize: 13, lineHeight: 1.5, overflowWrap: "anywhere" }}>
          {busy ? "Applying change…" : error || statusError || message}
        </div>
      </PanelSectionRow></PanelSection>}
    </>
  );
}

export default definePlugin(() => ({
  name: "SSH Switch",
  content: <Content />,
  icon: <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" width="1em" height="1em" aria-hidden="true"><path d="m4 5 6 6-6 6M13 18h7" /></svg>,
}));
