"""Portable checks for CI scope and concurrency contracts (no GitHub/Xcode)."""
from pathlib import Path
import re
import unittest


WORKFLOW = (Path(__file__).resolve().parents[1] / ".github/workflows/ios.yml").read_text()
JOBS = dict(re.findall(r"(?ms)^  (\w+):\n(.*?)(?=^  \w+:\n|\Z)", WORKFLOW.split("\njobs:\n", 1)[1]))


def expression(source, values):
    # Only simple workflow boolean expressions are accepted by this contract.
    for key in sorted(values, key=len, reverse=True):
        source = source.replace(key, repr(values[key]))
    source = source.replace("&&", " and ").replace("||", " or ")
    if re.search(r"\b(?:github|inputs)\.", source):
        raise ValueError("Unrecognized context in workflow expression")
    return eval(source, {"__builtins__": {}}, {})


def context(event="workflow_dispatch", job="native", test="all", branch="codex/2026-11-10", repository="owner/scanner"):
    return {"github.event_name": event, "inputs.job_scope": job, "inputs.test_scope": test,
            "github.workflow": "iOS workflow checks", "github.event.pull_request.head.repo.full_name": "",
            "github.repository": repository, "github.head_ref": "", "github.ref_name": branch,
            "inputs.image_session": "", "inputs.image_part": ""}


def selected_jobs(**kwargs):
    values = context(**kwargs)
    result = set()
    for name, block in JOBS.items():
        condition = re.search(r"(?m)^    if: \$\{\{ (.+) \}\}$", block)
        if condition is None or expression(condition.group(1), values):
            result.add(name)
    return result


class CIWorkflowTests(unittest.TestCase):
    def test_defaults_and_automatic_events_keep_full_ui_explicit(self):
        inputs = WORKFLOW.split("      job_scope:\n", 1)[1].split("      test_scope:\n", 1)[0]
        self.assertIn("        default: native\n", inputs)
        for event in ("push", "pull_request"):
            self.assertEqual(selected_jobs(event=event, job="", test=""), {"tooling", "native"})
        self.assertEqual(selected_jobs(job="all"), set(JOBS) - {"text_image_start", "text_image_part"})
        self.assertEqual(selected_jobs(job="tooling"), {"tooling"})
        self.assertEqual(selected_jobs(job="log_review"), {"tooling", "native", "ui"})
        self.assertEqual(selected_jobs(job="show_polish"), {"tooling", "native", "ui"})
        self.assertEqual(selected_jobs(job="leftover_stock"), {"tooling", "native", "ui"})
        self.assertEqual(selected_jobs(job="ui_diagnostic"), {"tooling", "ui"})
        for scope in ("all", "printer_transport", "navigation_price", "label_queue"):
            self.assertEqual(selected_jobs(job="ui_diagnostic", test=scope), {"tooling", "ui"})
            self.assertEqual(selected_jobs(job="log_review", test=scope), {"tooling", "native", "ui"})
            self.assertEqual(selected_jobs(job="show_polish", test=scope), {"tooling", "native", "ui"})
        self.assertEqual(selected_jobs(job="all", test="printer_transport"), {"tooling", "native", "release"})
        self.assertEqual(selected_jobs(job="all", test="navigation_price"), {"tooling", "native", "evidence_ui", "release"})

    def test_text_assist_forces_focused_native_without_unrelated_ui_or_release(self):
        self.assertIn("          - text_assist\n", WORKFLOW.split("      test_scope:\n", 1)[0])
        for test_scope in ("all", "printer_transport", "label_controls", "label_preview", "label_queue",
                           "show_readiness", "navigation_price", "camera_lifecycle"):
            with self.subTest(test_scope=test_scope):
                values = context(job="text_assist", test=test_scope)
                self.assertEqual(selected_jobs(job="text_assist", test=test_scope), {"tooling", "native"})
                scope = re.search(r"(?m)^          SCANNER_TEST_SCOPE: \$\{\{ (.+) \}\}$", JOBS["native"])
                self.assertIsNotNone(scope)
                self.assertEqual(expression(scope.group(1), values), "text_assist")

    def test_market_activity_forces_focused_native_and_chart_ui_only(self):
        self.assertIn("          - market_activity\n", WORKFLOW.split("      test_scope:\n", 1)[0])
        self.assertIn("CardShowScannerTests/CardImageQualityTests", JOBS["native"])
        self.assertIn("CardShowScannerUITests/CardImageQualityUITests", JOBS["evidence_ui"])
        for test_scope in ("all", "printer_transport", "label_controls", "label_preview", "label_queue",
                           "show_readiness", "navigation_price", "camera_lifecycle"):
            with self.subTest(test_scope=test_scope):
                values = context(job="market_activity", test=test_scope)
                self.assertEqual(selected_jobs(job="market_activity", test=test_scope), {"tooling", "native", "evidence_ui"})
                for name in ("native", "evidence_ui"):
                    scope = re.search(r"(?m)^          SCANNER_TEST_SCOPE: \$\{\{ (.+) \}\}$", JOBS[name])
                    self.assertIsNotNone(scope)
                    self.assertEqual(expression(scope.group(1), values), "market_activity")

    def test_download_preview_forces_focused_native_and_ui_without_other_jobs(self):
        self.assertIn("          - download_preview\n", WORKFLOW.split("      test_scope:\n", 1)[0])
        for test_scope in ("all", "printer_transport", "label_controls", "label_preview", "label_queue",
                           "show_readiness", "navigation_price", "camera_lifecycle"):
            with self.subTest(test_scope=test_scope):
                values = context(job="download_preview", test=test_scope)
                self.assertEqual(selected_jobs(job="download_preview", test=test_scope), {"tooling", "native", "ui"})
                for name in ("native", "ui"):
                    scope = re.search(r"(?m)^          SCANNER_TEST_SCOPE: \$\{\{ (.+) \}\}$", JOBS[name])
                    self.assertIsNotNone(scope)
                    self.assertEqual(expression(scope.group(1), values), "download_preview")

    def test_private_image_scopes_run_only_the_requested_transfer_phase(self):
        self.assertEqual(selected_jobs(job="text_image_start"), {"text_image_start"})
        self.assertEqual(selected_jobs(job="text_image_part"), {"text_image_part"})
        for event in ("push", "pull_request"):
            self.assertEqual(selected_jobs(event=event, job="", test=""), {"tooling", "native"})
        receiver = JOBS["text_image_start"]
        self.assertIn("scripts/scanner_text_image_transfer.py prepare", receiver)
        self.assertIn("scripts/scanner_text_image_transfer.py receive", receiver)
        self.assertIn("scripts/run_scanner_text_image_test.py", receiver)
        self.assertIn("actions: read", receiver)
        self.assertIn('run: rm -rf -- "$IMAGE_WORK_DIRECTORY"', receiver)
        self.assertIn("/public.pem", receiver)
        self.assertIn("/report.json", receiver)
        self.assertNotIn("path: ${{ env.IMAGE_WORK_DIRECTORY }}/image.jpg", receiver)
        self.assertNotIn("path: ${{ env.IMAGE_WORK_DIRECTORY }}/private.pem", receiver)
        self.assertIn("IMAGE_PAYLOAD: ${{ inputs.image_payload }}", JOBS["text_image_part"])

    def test_scanner_polish_forces_focused_native_and_manual_ui_without_other_jobs(self):
        self.assertIn("          - scanner_polish\n", WORKFLOW.split("      test_scope:\n", 1)[0])
        for test_scope in ("all", "printer_transport", "label_controls", "label_preview", "label_queue",
                           "show_readiness", "navigation_price", "camera_lifecycle"):
            with self.subTest(test_scope=test_scope):
                values = context(job="scanner_polish", test=test_scope)
                self.assertEqual(selected_jobs(job="scanner_polish", test=test_scope), {"tooling", "native", "ui"})
                for name in ("native", "ui"):
                    scope = re.search(r"(?m)^          SCANNER_TEST_SCOPE: \$\{\{ (.+) \}\}$", JOBS[name])
                    self.assertIsNotNone(scope)
                    self.assertEqual(expression(scope.group(1), values), "scanner_polish")

    def test_photo_scan_forces_focused_native_and_ui_without_other_jobs(self):
        self.assertIn("          - photo_scan\n", WORKFLOW.split("      test_scope:\n", 1)[0])
        for test_scope in ("all", "printer_transport", "label_controls", "label_preview", "label_queue",
                           "show_readiness", "navigation_price", "camera_lifecycle"):
            with self.subTest(test_scope=test_scope):
                values = context(job="photo_scan", test=test_scope)
                self.assertEqual(selected_jobs(job="photo_scan", test=test_scope), {"tooling", "native", "ui"})
                for name in ("native", "ui"):
                    scope = re.search(r"(?m)^          SCANNER_TEST_SCOPE: \$\{\{ (.+) \}\}$", JOBS[name])
                    self.assertIsNotNone(scope)
                    self.assertEqual(expression(scope.group(1), values), "photo_scan")

    def test_camera_lifecycle_selects_native_without_unrelated_ui_jobs(self):
        options = WORKFLOW.split("      test_scope:\n", 1)[1].split("\n# PRs", 1)[0]
        self.assertIn("          - camera_lifecycle", options.splitlines())
        self.assertEqual(selected_jobs(job="native", test="camera_lifecycle"), {"tooling", "native"})
        self.assertEqual(selected_jobs(job="all", test="camera_lifecycle"), {"tooling", "native", "release"})
        for job in ("ui", "research_ui", "evidence_ui", "budget_ui"):
            with self.subTest(job=job):
                self.assertEqual(selected_jobs(job=job, test="camera_lifecycle"), {"tooling"})
        scope = re.search(r"(?m)^          SCANNER_TEST_SCOPE: \$\{\{ (.+) \}\}$", JOBS["native"])
        self.assertIsNotNone(scope)
        self.assertEqual(expression(scope.group(1), context(job="native", test="camera_lifecycle")), "camera_lifecycle")

    def test_linux_project_checker_dependencies_are_installed_before_checks(self):
        tooling = JOBS["tooling"]
        setup = tooling.index("uses: actions/setup-python@v5")
        install = tooling.index("python3 -m pip install --disable-pip-version-check -r scripts/requirements-ci.txt")
        self.assertIn("python-version: '3.12'", tooling)
        self.assertLess(setup, install)
        self.assertLess(install, tooling.index("python3 -m unittest discover"))
        self.assertLess(install, tooling.index("python3 scripts/check_xcode_sources.py"))
        requirements = (Path(__file__).parent / "requirements-ci.txt").read_text()
        self.assertRegex(requirements, r"(?m)^openstep-parser==2\.0\.3$")

    def test_show_polish_forces_full_native_and_focused_ui_without_unrelated_jobs(self):
        self.assertIn("          - show_polish\n", WORKFLOW.split("      test_scope:\n", 1)[0])
        for test_scope in ("all", "printer_transport", "label_controls", "label_preview", "label_queue", "show_readiness", "navigation_price"):
            with self.subTest(test_scope=test_scope):
                values = context(job="show_polish", test=test_scope)
                self.assertEqual(selected_jobs(job="show_polish", test=test_scope), {"tooling", "native", "ui"})
                for name, expected in (("native", "all"), ("ui", "show_polish")):
                    scope = re.search(r"(?m)^          SCANNER_TEST_SCOPE: \$\{\{ (.+) \}\}$", JOBS[name])
                    self.assertIsNotNone(scope)
                    self.assertEqual(expression(scope.group(1), values), expected)

    def test_leftover_stock_forces_full_native_and_focused_ui_without_unrelated_jobs(self):
        self.assertIn("          - leftover_stock\n", WORKFLOW.split("      test_scope:\n", 1)[0])
        for test_scope in ("all", "printer_transport", "label_controls", "label_preview", "label_queue", "show_readiness", "navigation_price"):
            with self.subTest(test_scope=test_scope):
                values = context(job="leftover_stock", test=test_scope)
                self.assertEqual(selected_jobs(job="leftover_stock", test=test_scope), {"tooling", "native", "ui"})
                for name, expected in (("native", "all"), ("ui", "leftover_stock")):
                    scope = re.search(r"(?m)^          SCANNER_TEST_SCOPE: \$\{\{ (.+) \}\}$", JOBS[name])
                    self.assertIsNotNone(scope)
                    self.assertEqual(expression(scope.group(1), values), expected)

    def test_push_and_pr_do_not_duplicate_work_branch_runs(self):
        push = WORKFLOW.split("  push:\n", 1)[1].split("  pull_request:", 1)[0]
        self.assertEqual(re.findall(r"^      - (.+)$", push, re.M), ["main"])
        self.assertIn("  pull_request:\n", WORKFLOW)

    def test_concurrency_cancels_superseded_not_unrelated_scopes(self):
        block = WORKFLOW.split("\nconcurrency:\n", 1)[1].split("\npermissions:\n", 1)[0]
        self.assertIn("  cancel-in-progress: true", block)
        group = re.search(r"(?m)^  group: (.+)$", block).group(1)
        self.assertNotIn("github.sha", group)

        def key(values):
            return re.sub(r"\$\{\{ (.+?) \}\}", lambda match: str(expression(match.group(1), values)), group)

        regular = context()
        self.assertNotEqual(key(regular), key(context(job="ui")))
        self.assertNotEqual(key(regular), key(context(test="printer_transport")))
        self.assertNotEqual(key(regular), key(context(branch="other")))
        fork = context()
        fork["github.event.pull_request.head.repo.full_name"] = "contributor/scanner"
        self.assertNotEqual(key(regular), key(fork))
        automatic = context(event="pull_request", job="", test="")
        automatic["github.head_ref"] = regular["github.ref_name"]
        automatic["github.ref_name"] = "12/merge"
        self.assertEqual(key(regular), key(automatic))
        first = context(job="text_image_part")
        first["inputs.image_session"] = "session-a"
        first["inputs.image_part"] = "0"
        second = first.copy()
        second["inputs.image_part"] = "1"
        self.assertNotEqual(key(first), key(second), "Payload parts must not cancel each other")

    def test_diagnostic_and_release_commands_are_bounded(self):
        self.assertIn("testBatchSearchCopiesPreviewAndLeavingUnprintedQueueClearsBeforeRelaunch", JOBS["ui"])
        self.assertIn("inputs.job_scope == 'ui_diagnostic' && '900' || '3600'", JOBS["ui"])
        for name in ("native", "ui", "research_ui", "evidence_ui", "budget_ui"):
            self.assertIn("process_budget.py --seconds 120 -- xcrun xcresulttool", JOBS[name])
        self.assertIn('process_budget.py --seconds "$SCANNER_BUILD_TIMEOUT_SECONDS" --log NativeRelease.log -- xcodebuild', JOBS["release"])
        self.assertIn("runs-on: ubuntu-latest", JOBS["tooling"])


if __name__ == "__main__":
    unittest.main()
