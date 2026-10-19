#!/usr/bin/env python3
"""Palmont Stream Studio — a polished Tkinter front end for the section-pack builder.

Standard-library-only GUI. On Windows, run with: py palmont_stream_studio.py
"""
from __future__ import annotations

import os
import queue
import subprocess
import sys
import threading
import traceback
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk
from typing import Any

from build_palmont_stream_pack import analyze_source, build_stream_pack

APP_NAME = "Palmont Stream Studio"
BG = "#0b1220"
PANEL = "#111c2e"
PANEL_2 = "#162338"
FIELD = "#091321"
TEXT = "#edf4ff"
MUTED = "#91a4c0"
ACCENT = "#55d6be"
ACCENT_2 = "#65a7ff"
WARNING = "#f2c879"
ERROR = "#ff8d9d"


class StreamStudio(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title(APP_NAME)
        self.configure(bg=BG)
        self.geometry("1160x830")
        self.minsize(930, 700)

        self.source_var = tk.StringVar()
        self.output_var = tk.StringVar(value=str(Path.home() / "Documents" / "Palmont_Stream_Staging"))
        self.vfs_var = tk.StringVar(value="levels/nfsc")
        self.status_var = tk.StringVar(value="Choose your exported item file or the full level folder to begin.")
        self.mode_var = tk.StringVar(value="Auto-detect: one file or a folder")
        self.busy = False
        self.msg_queue: queue.Queue[tuple[str, Any]] = queue.Queue()
        self.last_report: dict[str, Any] | None = None
        self.last_input_kind = ""
        self._setup_style()
        self._build_layout()
        self.after(100, self._poll_messages)

    def _setup_style(self) -> None:
        style = ttk.Style(self)
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure("TFrame", background=BG)
        style.configure("Panel.TFrame", background=PANEL)
        style.configure("Inner.TFrame", background=PANEL_2)
        style.configure("TLabel", background=BG, foreground=TEXT, font=("Segoe UI", 10))
        style.configure("Muted.TLabel", background=BG, foreground=MUTED, font=("Segoe UI", 9))
        style.configure("Panel.TLabel", background=PANEL, foreground=TEXT, font=("Segoe UI", 10))
        style.configure("PanelMuted.TLabel", background=PANEL, foreground=MUTED, font=("Segoe UI", 9))
        style.configure("Hero.TLabel", background=BG, foreground=TEXT, font=("Segoe UI Semibold", 22))
        style.configure("Subhero.TLabel", background=BG, foreground=MUTED, font=("Segoe UI", 10))
        style.configure("Section.TLabel", background=PANEL, foreground=TEXT, font=("Segoe UI Semibold", 11))
        style.configure("Metric.TLabel", background=PANEL_2, foreground=ACCENT, font=("Segoe UI Semibold", 20))
        style.configure("MetricCaption.TLabel", background=PANEL_2, foreground=MUTED, font=("Segoe UI", 9))
        style.configure("TEntry", fieldbackground=FIELD, foreground=TEXT, insertcolor=TEXT,
                        bordercolor="#2b3b55", lightcolor="#2b3b55", darkcolor="#2b3b55", padding=7)
        style.configure("TSpinbox", fieldbackground=FIELD, foreground=TEXT, insertcolor=TEXT,
                        bordercolor="#2b3b55", lightcolor="#2b3b55", darkcolor="#2b3b55", padding=6)
        style.configure("TButton", background=PANEL_2, foreground=TEXT, padding=(12, 8),
                        borderwidth=0, font=("Segoe UI Semibold", 9))
        style.map("TButton", background=[("active", "#263b58"), ("disabled", "#202b3c")],
                  foreground=[("disabled", "#67758a")])
        style.configure("Primary.TButton", background=ACCENT, foreground="#071720", padding=(18, 10),
                        font=("Segoe UI Semibold", 10))
        style.map("Primary.TButton", background=[("active", "#7be7d1"), ("disabled", "#2b7165")])
        style.configure("Secondary.TButton", background="#203552", foreground=TEXT, padding=(14, 9))
        style.configure("TLabelframe", background=PANEL, bordercolor="#27364d", relief="flat")
        style.configure("TLabelframe.Label", background=PANEL, foreground=TEXT, font=("Segoe UI Semibold", 10))
        style.configure("TNotebook", background=BG, borderwidth=0)
        style.configure("TNotebook.Tab", background=PANEL, foreground=MUTED, padding=(14, 8),
                        font=("Segoe UI Semibold", 9))
        style.map("TNotebook.Tab", background=[("selected", PANEL_2)], foreground=[("selected", TEXT)])
        style.configure("Treeview", background=FIELD, fieldbackground=FIELD, foreground=TEXT,
                        bordercolor="#25354c", rowheight=27, font=("Segoe UI", 9))
        style.configure("Treeview.Heading", background=PANEL_2, foreground=TEXT, relief="flat",
                        font=("Segoe UI Semibold", 9), padding=(8, 7))
        style.map("Treeview", background=[("selected", "#24486a")], foreground=[("selected", "#ffffff")])
        style.configure("Horizontal.TProgressbar", background=ACCENT, troughcolor=FIELD, bordercolor=FIELD,
                        lightcolor=ACCENT, darkcolor=ACCENT)

    def _build_layout(self) -> None:
        root = ttk.Frame(self, padding=(24, 20, 24, 14))
        root.pack(fill="both", expand=True)

        header = ttk.Frame(root)
        header.pack(fill="x", pady=(0, 16))
        brand = ttk.Frame(header)
        brand.pack(side="left", fill="x", expand=True)
        ttk.Label(brand, text="PALMONT / STREAM STUDIO", style="Hero.TLabel").pack(anchor="w")
        ttk.Label(brand, text="Section-streaming pack builder · non-destructive post-export workflow",
                  style="Subhero.TLabel").pack(anchor="w", pady=(3, 0))
        ttk.Label(header, text="SOURCE-SAFE", foreground=ACCENT, background=PANEL_2,
                  padding=(12, 8), font=("Segoe UI Semibold", 9)).pack(side="right", anchor="n")

        source_card = ttk.Frame(root, style="Panel.TFrame", padding=16)
        source_card.pack(fill="x", pady=(0, 12))
        ttk.Label(source_card, text="01  ·  SOURCE", style="Section.TLabel").grid(row=0, column=0, sticky="w", columnspan=3)
        ttk.Label(source_card, text="Select one exported JSONL file, or a level folder to scan for every items.level.json.",
                  style="PanelMuted.TLabel").grid(row=1, column=0, sticky="w", columnspan=3, pady=(4, 9))
        self.source_entry = ttk.Entry(source_card, textvariable=self.source_var)
        self.source_entry.grid(row=2, column=0, sticky="ew", padx=(0, 8))
        ttk.Button(source_card, text="Browse file…", command=self._browse_file).grid(row=2, column=1, padx=(0, 7))
        ttk.Button(source_card, text="Browse folder…", command=self._browse_folder).grid(row=2, column=2)
        source_card.columnconfigure(0, weight=1)

        options = ttk.Frame(root)
        options.pack(fill="x", pady=(0, 12))
        out_card = ttk.Frame(options, style="Panel.TFrame", padding=16)
        out_card.pack(side="left", fill="both", expand=True, padx=(0, 6))
        ttk.Label(out_card, text="02  ·  STAGING DESTINATION", style="Section.TLabel").pack(anchor="w")
        ttk.Label(out_card, text="Patched item files and whole-section files go here; source files stay in place.",
                  style="PanelMuted.TLabel").pack(anchor="w", pady=(4, 9))
        out_row = ttk.Frame(out_card, style="Panel.TFrame")
        out_row.pack(fill="x")
        ttk.Entry(out_row, textvariable=self.output_var).pack(side="left", fill="x", expand=True, padx=(0, 8))
        ttk.Button(out_row, text="Browse…", command=self._browse_output).pack(side="right")

        config_card = ttk.Frame(options, style="Panel.TFrame", padding=16)
        config_card.pack(side="left", fill="y", padx=(6, 0))
        ttk.Label(config_card, text="03  ·  RUNTIME SETTINGS", style="Section.TLabel").pack(anchor="w")
        config_grid = ttk.Frame(config_card, style="Panel.TFrame")
        config_grid.pack(fill="x", pady=(10, 0))
        ttk.Label(config_grid, text="Level VFS path", style="PanelMuted.TLabel").grid(row=0, column=0, sticky="w", padx=(0, 12))
        ttk.Entry(config_grid, textvariable=self.vfs_var, width=23).grid(row=0, column=1, sticky="ew")
        config_grid.columnconfigure(1, weight=1)

        action_row = ttk.Frame(root)
        action_row.pack(fill="x", pady=(0, 12))
        ttk.Button(action_row, text="Analyze & Preview", style="Secondary.TButton",
                   command=self._analyze).pack(side="left")
        self.build_button = ttk.Button(action_row, text="Build Staging Pack  →", style="Primary.TButton",
                                       command=self._build)
        self.build_button.pack(side="left", padx=(8, 0))
        ttk.Button(action_row, text="Open Staging Folder", command=self._open_output).pack(side="right")

        metrics = ttk.Frame(root)
        metrics.pack(fill="x", pady=(0, 12))
        self.metric_values: dict[str, ttk.Label] = {}
        for key, label in (("files", "INPUT FILES"), ("records", "JSON RECORDS"),
                           ("streamable", "STREAMABLE TSSTATIC"), ("sections", "SECTIONS")):
            card = ttk.Frame(metrics, style="Inner.TFrame", padding=(14, 11))
            card.pack(side="left", fill="x", expand=True, padx=(0, 8) if key != "sections" else 0)
            value = ttk.Label(card, text="—", style="Metric.TLabel")
            value.pack(anchor="w")
            ttk.Label(card, text=label, style="MetricCaption.TLabel").pack(anchor="w", pady=(2, 0))
            self.metric_values[key] = value

        notebook = ttk.Notebook(root)
        notebook.pack(fill="both", expand=True)
        self.sections_tab = ttk.Frame(notebook, style="Panel.TFrame", padding=10)
        self.log_tab = ttk.Frame(notebook, style="Panel.TFrame", padding=10)
        notebook.add(self.sections_tab, text="Section Preview")
        notebook.add(self.log_tab, text="Build Log")

        columns = ("section", "count", "samples")
        self.section_tree = ttk.Treeview(self.sections_tab, columns=columns, show="headings", height=8)
        self.section_tree.heading("section", text="SECTION ID")
        self.section_tree.heading("count", text="OBJECT RECORDS")
        self.section_tree.heading("samples", text="SAMPLE OBJECTS")
        self.section_tree.column("section", width=130, anchor="center", stretch=False)
        self.section_tree.column("count", width=150, anchor="center", stretch=False)
        self.section_tree.column("samples", width=650, anchor="w")
        tree_scroll = ttk.Scrollbar(self.sections_tab, orient="vertical", command=self.section_tree.yview)
        self.section_tree.configure(yscrollcommand=tree_scroll.set)
        self.section_tree.pack(side="left", fill="both", expand=True)
        tree_scroll.pack(side="right", fill="y")

        self.log_text = tk.Text(self.log_tab, bg=FIELD, fg=TEXT, insertbackground=TEXT,
                                selectbackground="#24486a", relief="flat", bd=0,
                                font=("Cascadia Mono", 9), wrap="word", padx=12, pady=10,
                                state="disabled")
        log_scroll = ttk.Scrollbar(self.log_tab, orient="vertical", command=self.log_text.yview)
        self.log_text.configure(yscrollcommand=log_scroll.set)
        self.log_text.pack(side="left", fill="both", expand=True)
        log_scroll.pack(side="right", fill="y")
        self.log_text.tag_configure("ok", foreground=ACCENT)
        self.log_text.tag_configure("warn", foreground=WARNING)
        self.log_text.tag_configure("err", foreground=ERROR)
        self.log_text.tag_configure("muted", foreground=MUTED)

        footer = ttk.Frame(root)
        footer.pack(fill="x", pady=(10, 0))
        self.progress = ttk.Progressbar(footer, mode="indeterminate", length=140)
        self.progress.pack(side="left", padx=(0, 10))
        ttk.Label(footer, textvariable=self.status_var, style="Muted.TLabel").pack(side="left", fill="x", expand=True)
        ttk.Label(footer, text="Camera-driven sections · original export untouched",
                  style="Muted.TLabel").pack(side="right", padx=(10, 0))

        self._append_log("Ready. Source format: one JSON object per non-empty line.", "muted")
        self._append_log("The sample schema's rotationEuler fields are kept in the generated section records.", "muted")

    def _browse_file(self) -> None:
        initial = self.source_var.get().strip()
        initial_dir = initial if Path(initial).is_dir() else (str(Path(initial).parent) if initial else str(Path.home()))
        path = filedialog.askopenfilename(
            title="Select exported items.level.json or JSONL item file",
            initialdir=initial_dir,
            filetypes=[("JSON / JSONL files", "*.json *.jsonl"), ("All files", "*.*")],
        )
        if path:
            self.source_var.set(path)
            self.status_var.set("Single-file input selected. Analyze it before building.")

    def _browse_folder(self) -> None:
        initial = self.source_var.get().strip()
        initial_dir = initial if Path(initial).is_dir() else (str(Path(initial).parent) if initial else str(Path.home()))
        path = filedialog.askdirectory(title="Select level root folder", initialdir=initial_dir, mustexist=True)
        if path:
            self.source_var.set(path)
            self.status_var.set("Folder input selected. All items.level.json files below it will be scanned.")

    def _browse_output(self) -> None:
        initial = self.output_var.get().strip()
        initial_dir = str(Path(initial).parent) if initial else str(Path.home())
        path = filedialog.askdirectory(title="Choose staging output folder", initialdir=initial_dir, mustexist=False)
        if path:
            self.output_var.set(path)

    def _append_log(self, text: str, tag: str | None = None) -> None:
        self.log_text.configure(state="normal")
        if tag:
            self.log_text.insert("end", text.rstrip() + "\n", tag)
        else:
            self.log_text.insert("end", text.rstrip() + "\n")
        self.log_text.see("end")
        self.log_text.configure(state="disabled")

    def _clear_log(self) -> None:
        self.log_text.configure(state="normal")
        self.log_text.delete("1.0", "end")
        self.log_text.configure(state="disabled")

    def _get_parameters(self) -> tuple[Path, Path, str, int] | None:
        source_text = self.source_var.get().strip().strip('"')
        output_text = self.output_var.get().strip().strip('"')
        if not source_text:
            messagebox.showwarning(APP_NAME, "Choose the exported file or level folder first.")
            return None
        if not output_text:
            messagebox.showwarning(APP_NAME, "Choose a staging output folder first.")
            return None
        if not self.vfs_var.get().strip():
            messagebox.showwarning(APP_NAME, "Enter the level VFS path, e.g. levels/nfsc.")
            return None
        return Path(source_text), Path(output_text), self.vfs_var.get().strip()

    def _start_worker(self, task: str) -> None:
        if self.busy:
            return
        params = self._get_parameters()
        if params is None:
            return
        source, out, vfs = params
        if task == "build":
            try:
                source_resolved = source.expanduser().resolve()
                root = source_resolved.parent if source_resolved.is_file() else source_resolved
                output_resolved = out.expanduser().resolve()
                if output_resolved == root or root in output_resolved.parents:
                    messagebox.showerror(APP_NAME,
                        "For safety, staging output must be outside the source directory.\n\n"
                        "Choose a separate folder (for example E:\\BeamNG\\palmont_stream_stage).")
                    return
            except OSError as exc:
                messagebox.showerror(APP_NAME, str(exc))
                return
        self.busy = True
        self.build_button.configure(state="disabled")
        self.progress.start(12)
        self.status_var.set("Reading source…" if task == "analyze" else "Building staging pack…")
        self._append_log("", "muted")
        self._append_log("Starting source analysis…" if task == "analyze" else "Starting staging build…", "muted")

        def progress(message: str) -> None:
            self.msg_queue.put(("log", message))

        def worker() -> None:
            try:
                if task == "analyze":
                    result = analyze_source(source, progress=progress)
                    self.msg_queue.put(("analysis_done", result))
                else:
                    report = build_stream_pack(source, out, vfs, progress=progress)
                    self.msg_queue.put(("build_done", report))
            except Exception as exc:  # deliver context from worker to UI thread
                self.msg_queue.put(("error", (str(exc), traceback.format_exc())))
            finally:
                self.msg_queue.put(("finished", None))

        threading.Thread(target=worker, daemon=True).start()

    def _analyze(self) -> None:
        self._start_worker("analyze")

    def _build(self) -> None:
        params = self._get_parameters()
        if params is None:
            return
        source, out, _vfs = params
        if not messagebox.askyesno(
            APP_NAME,
            "Build a staging pack from this source?\n\n"
            f"Source: {source}\n"
            f"Output: {out}\n\n"
            "The source export will not be edited. The build creates patched copies and generated runtime data only."
        ):
            return
        self._start_worker("build")

    def _open_output(self) -> None:
        value = self.output_var.get().strip().strip('"')
        if not value:
            return
        path = Path(value).expanduser()
        if not path.exists():
            messagebox.showinfo(APP_NAME, "The staging folder has not been created yet.")
            return
        try:
            if sys.platform.startswith("win"):
                os.startfile(str(path))  # type: ignore[attr-defined]
            elif sys.platform == "darwin":
                subprocess.Popen(["open", str(path)])
            else:
                subprocess.Popen(["xdg-open", str(path)])
        except Exception as exc:
            messagebox.showerror(APP_NAME, f"Could not open the output folder:\n{exc}")

    def _set_metrics(self, stats: dict[str, Any]) -> None:
        files = stats.get("sourceFileCount", stats.get("sourceItemFiles", 0))
        records = stats.get("recordCount", stats.get("sourceObjectRecords", 0))
        streamable = stats.get("streamableUniqueRecords", stats.get("streamedUniqueRecords", 0))
        sections = stats.get("sectionCount", len(stats.get("sections", [])))
        self.metric_values["files"].configure(text=f"{files:,}")
        self.metric_values["records"].configure(text=f"{records:,}")
        self.metric_values["streamable"].configure(text=f"{streamable:,}")
        self.metric_values["sections"].configure(text=f"{sections:,}")

    def _fill_sections(self, sections: list[dict[str, Any]]) -> None:
        for row in self.section_tree.get_children():
            self.section_tree.delete(row)
        for section in sections:
            samples = section.get("samples")
            if samples is None:
                samples = []
            self.section_tree.insert("", "end", values=(
                section.get("id", "?"),
                f"{section.get('recordCopies', section.get('count', 0)):,}",
                ", ".join(str(name) for name in samples[:3]),
            ))

    def _poll_messages(self) -> None:
        try:
            while True:
                kind, payload = self.msg_queue.get_nowait()
                if kind == "log":
                    self._append_log(str(payload), "muted")
                    self.status_var.set(str(payload))
                elif kind == "analysis_done":
                    self.last_report = payload
                    self.last_input_kind = "analysis"
                    self._set_metrics(payload)
                    self._fill_sections(payload.get("sections", []))
                    self._append_log("Analysis finished — no files were written.", "ok")
                    self._append_log(f"Source mode: {payload.get('inputMode')} · source root: {payload.get('sourceRoot')}")
                    self._append_log(f"rotationEuler records: {payload.get('rotationEulerRecords', 0):,}; quaternion records: {payload.get('rotationQuaternionRecords', 0):,}")
                    self._append_log(f"TSStatic left in normal load due to missing shapeName: {payload.get('TSStaticWithoutShapeName', 0):,}", "warn")
                    self._append_log(f"TSStatic left in normal load due to unusable sectionID: {payload.get('TSStaticWithoutUsableSectionID', 0):,}", "warn")
                    self.status_var.set("Analysis complete. Review section counts, then build a staging pack.")
                elif kind == "build_done":
                    self.last_report = payload
                    self.last_input_kind = "build"
                    self._set_metrics(payload)
                    self._fill_sections([{"id": sec.get("id"), "recordCopies": sec.get("count", 0), "samples": []}
                                         for sec in payload.get("sections", [])])
                    self._append_log("BUILD COMPLETE — source export was not modified.", "ok")
                    self._append_log(f"Patch copies: {payload.get('patchOutputRoot')}", "ok")
                    self._append_log(f"Runtime data: {payload.get('runtimeOutputRoot')}", "ok")
                    self._append_log(f"Report: {Path(payload.get('patchOutputRoot', '.')).parent / 'build_report.json'}")
                    self._append_log("Next step: inspect build_report.json; then manually copy staged patches into a TEST level.", "warn")
                    self.status_var.set("Staging pack built. No source files were changed.")
                    messagebox.showinfo(APP_NAME,
                        "Staging pack built successfully.\n\n"
                        f"Streamable records: {payload.get('streamedUniqueRecords', 0):,}\n"
                        f"Sections: {payload.get('sectionCount', 0):,}\n\n"
                        "The source export is untouched. Review build_report.json before installing anything.")
                elif kind == "error":
                    message, tb = payload
                    self._append_log(f"ERROR: {message}", "err")
                    self._append_log(tb, "muted")
                    self.status_var.set("Task failed. Details are in Build Log.")
                    messagebox.showerror(APP_NAME, f"Operation failed:\n\n{message}")
                elif kind == "finished":
                    self.busy = False
                    self.progress.stop()
                    self.build_button.configure(state="normal")
        except queue.Empty:
            pass
        self.after(100, self._poll_messages)


def main() -> None:
    app = StreamStudio()
    app.mainloop()


if __name__ == "__main__":
    main()
