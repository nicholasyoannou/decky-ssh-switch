import { callable, definePlugin } from "@decky/api";
import { ButtonItem, ConfirmModal, PanelSection, PanelSectionRow, TextField, ToggleField, showModal, staticClasses } from "@decky/ui";
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
const setEnabled = callable<[boolean], Status>("set_enabled");
const setStartup = callable<[boolean], Status>("set_startup");
const setPassword = callable<[string], { username: string; changed: boolean }>("set_password");
// Current Steam forwards native input props, although Decky's type declaration
// only lists the legacy bIsPassword flag. Supply both for runtime compatibility.
const passwordInputProps = { type: "password", autoComplete: "new-password" } as const;

interface PasswordDialogProps {
  username: string;
  onChanged: (username: string) => void;
  closeModal?: () => void;
}

function PasswordDialog({ username, onChanged, closeModal }: PasswordDialogProps) {
  const [password, updatePassword] = useState("");
  const [confirmation, updateConfirmation] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const inFlight = useRef(false);
  const mounted = useRef(false);
  const blankPassword = password.trim().length === 0;
  const mismatch = confirmation.length > 0 && password !== confirmation;

  useEffect(() => {
    mounted.current = true;
    return () => { mounted.current = false; };
  }, []);

  function dismiss() {
    if (!inFlight.current) closeModal?.();
  }

  async function savePassword() {
    if (inFlight.current || blankPassword || password !== confirmation) return;
    inFlight.current = true;
    setBusy(true);
    setError("");
    // Clear both fields immediately, including when the system rejects a change.
    const value = password;
    updatePassword("");
    updateConfirmation("");
    try {
      const result = await setPassword(value);
      if (!result.changed) throw new Error("Password change was not confirmed.");
      if (mounted.current) {
        onChanged(result.username);
        closeModal?.();
      }
    } catch {
      // Do not reflect an RPC exception that could include its request payload.
      if (mounted.current) setError("The system could not update the password. If the request timed out, check which password works before retrying.");
    } finally {
      inFlight.current = false;
      if (mounted.current) setBusy(false);
    }
  }

  return (
    <ConfirmModal
      strTitle="Set password"
      strDescription={<>Changes the Linux password for <strong>{username}</strong>, used by SSH and sudo.</>}
      strOKButtonText={busy ? "Saving…" : "Save password"}
      strCancelButtonText="Cancel"
      bOKDisabled={busy || blankPassword || password !== confirmation}
      bCancelDisabled={busy}
      bDisableBackgroundDismiss={busy}
      bHideCloseIcon={busy}
      onOK={savePassword}
      onCancel={dismiss}
    >
      {/* Keep closeModal on this component so Steam only closes after a successful save. */}
      <div style={{ marginTop: 16 }}>
        <TextField {...passwordInputProps} label="New password" bIsPassword bShowCopyAction={false} value={password} disabled={busy} onChange={(event) => updatePassword(event.target.value)} />
      </div>
      <div style={{ marginTop: 16 }}>
        <TextField {...passwordInputProps} label="Confirm password" bIsPassword bShowCopyAction={false} value={confirmation} disabled={busy} onChange={(event) => updateConfirmation(event.target.value)} />
      </div>
      {(busy || error || mismatch) && <div role={error || mismatch ? "alert" : "status"} style={{ fontSize: 14, lineHeight: 1.5, marginTop: 16 }}>
        {busy ? "Updating password…" : error || "The passwords do not match."}
      </div>}
    </ConfirmModal>
  );
}

function Content() {
  const [status, setStatus] = useState<Status | null>(null);
  const [busy, setBusy] = useState(false);
  const [reading, setReading] = useState(false);
  const [error, setError] = useState("");
  const [statusError, setStatusError] = useState("");
  const [message, setMessage] = useState("");
  const inFlight = useRef(false);
  const mounted = useRef(false);

  async function refresh() {
    if (inFlight.current) return;
    inFlight.current = true;
    if (mounted.current) setReading(true);
    try {
      const next = await getStatus();
      if (mounted.current) {
        setStatus(next);
        setStatusError("");
      }
    } catch (reason) {
      if (mounted.current) {
        setStatus(null);
        setStatusError(reason instanceof Error ? reason.message : String(reason));
      }
    } finally {
      inFlight.current = false;
      if (mounted.current) setReading(false);
    }
  }

  useEffect(() => {
    mounted.current = true;
    void refresh();
    const timer = window.setInterval(() => void refresh(), 5000);
    return () => {
      mounted.current = false;
      window.clearInterval(timer);
    };
  }, []);

  async function changeSwitch(kind: "running" | "startup", enabled: boolean) {
    if (inFlight.current) return;
    inFlight.current = true;
    setBusy(true);
    setError("");
    setMessage("");
    try {
      const next = await (kind === "running" ? setEnabled(enabled) : setStartup(enabled));
      if (mounted.current) setStatus(next);
    } catch (reason) {
      if (mounted.current) {
        setError(reason instanceof Error ? reason.message : String(reason));
        // A failed command may have partially changed system state. Keep the
        // error visible, but re-read systemd instead of showing a stale toggle.
        try {
          const next = await getStatus();
          if (mounted.current) setStatus(next);
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

  const disabled = busy || reading || !status || status.transitioning;
  return (
    <>
      <PanelSection title="SSH">
        <PanelSectionRow>
          <ToggleField
            label="SSH enabled"
            description={status ? (status.transitioning ? "SSH is changing state…" : status.masked ? "SSH is masked in system settings." : status.running ? "Remote connections are on." : "Remote connections are off.") : statusError ? "SSH status is unavailable." : "Checking SSH status…"}
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
          <ButtonItem layout="below" disabled={busy || reading} onClick={() => { setError(""); void refresh(); }}>Refresh status</ButtonItem>
        </PanelSectionRow>
        <PanelSectionRow>
          <ButtonItem layout="below" disabled={busy || reading} onClick={openPasswordDialog}>Set password</ButtonItem>
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
  titleView: <div className={staticClasses.Title}>SSH Switch</div>,
  content: <Content />,
  icon: <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" width="1em" height="1em" aria-hidden="true"><path d="m4 5 6 6-6 6M13 18h7" /></svg>,
}));
