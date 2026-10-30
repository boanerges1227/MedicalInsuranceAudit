"""Verify incremental resource versions, out-of-order updates, and Bundle atomicity through real HTTP requests."""
import copy
import json
import os
import time
import unittest
import uuid

from test_demo import ROOT, call


class ResourceVersionTest(unittest.TestCase):
    """Use a separate encounter and event for each test to avoid cross-test contamination."""

    def setUp(self):
        """Prepare a synthetic encounter with two orders for the same medication."""
        with open(os.path.join(ROOT, "samples", "encounter-bundle.json"), encoding="utf-8") as source:
            sample = source.read()
        suffix = uuid.uuid4().hex[:12]
        self.encounter = "enc-ver-" + suffix
        self.bundle = json.loads(sample.replace("enc-demo-001", self.encounter))
        self.encounter_resource = next(e["resource"] for e in self.bundle["entry"]
                                       if e["resource"]["resourceType"] == "Encounter")
        self.meds = [e["resource"] for e in self.bundle["entry"]
                     if e["resource"]["resourceType"] == "MedicationRequest"]

    def submit(self, resources):
        """Submit a new event; incremental Bundles always include the Encounter needed to identify the case."""
        bundle = {"resourceType": "Bundle", "type": "collection", "id": "version-" + uuid.uuid4().hex,
                  "entry": [{"resource": copy.deepcopy(self.encounter_resource)}] +
                           [{"resource": copy.deepcopy(resource)} for resource in resources]}
        return call("/api/fhir", "POST", bundle, fhir=True)

    def accepted(self, status, response):
        """After asynchronous acceptance, poll by event ID to avoid reading the previous event's result."""
        self.assertEqual(status, 200, response)
        self.assertIn(response["status"], ("PROCESSING", "PENDING_REVIEW"), response)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            status, detail = call("/api/cases/" + self.encounter)
            self.assertEqual(status, 200, detail)
            if detail.get("eventId") == response["eventId"] and detail.get("status") == "PENDING_REVIEW":
                return detail
            time.sleep(0.1)
        self.fail("审核事件未在规定时间内完成：" + repr(response))

    def initial(self, versions=True):
        """Submit the initial complete set and verify later incremental updates retain other resources."""
        resources = [copy.deepcopy(e["resource"]) for e in self.bundle["entry"]
                     if e["resource"]["resourceType"] != "Encounter"]
        if versions:
            for resource in resources:
                if resource["resourceType"] == "MedicationRequest":
                    resource["meta"] = {"versionId": "1"}
        return self.accepted(*self.submit(resources))

    def med(self, index, version, status="active"):
        """Build the selected resource version and clinical status."""
        med = copy.deepcopy(self.meds[index])
        med["status"] = status
        if version is not None:
            med["meta"] = {"versionId": version}
        return med

    def conflict(self, resources, code):
        """Check the conflict HTTP status and the distinct client-facing error code."""
        status, response = self.submit(resources)
        self.assertEqual(status, 409, response)
        self.assertEqual(response.get("error"), code, response)

    def test_incremental_stop_preserves_absent_resources(self):
        """Stop one order only; preserve the omitted order while clearing the duplicate medication finding."""
        before = self.initial()
        self.assertTrue(any(r["id"].startswith("risk-duplicate-") for r in before["risks"]))
        after = self.accepted(*self.submit([self.med(0, "2", "stopped")]))
        self.assertFalse(any(r["id"].startswith("risk-duplicate-") for r in after["risks"]), after)
        # Preserve the clinical record and the other active order when they are absent from an incremental Bundle.
        self.assertTrue(any(r["id"] == "risk-renal-med" for r in after["risks"]), after)

    def test_equal_stale_and_numeric_order(self):
        """Accept identical content at the same version idempotently; reject changed content or older versions."""
        self.initial()
        self.accepted(*self.submit([self.med(0, "1")]))
        self.conflict([self.med(0, "1", "stopped")], "RESOURCE_VERSION_CONFLICT")
        self.accepted(*self.submit([self.med(0, "2")]))
        self.accepted(*self.submit([self.med(0, "10")]))
        # Compare versions numerically: 2 is less than 10, and 0 is a valid nonnegative version.
        self.conflict([self.med(0, "2", "stopped")], "STALE_RESOURCE_VERSION")
        self.conflict([self.med(0, "0")], "STALE_RESOURCE_VERSION")

    def test_conflict_rolls_back_entire_bundle(self):
        """Roll back all resource changes if a later resource conflicts after an earlier one passed validation."""
        before = self.initial()
        self.conflict([self.med(0, "2", "stopped"), self.med(1, "1", "stopped")],
                      "RESOURCE_VERSION_CONFLICT")
        status, unchanged = call("/api/cases/" + self.encounter)
        self.assertEqual(status, 200, unchanged)
        self.assertEqual(unchanged["eventId"], before["eventId"])
        self.assertEqual(unchanged["version"], before["version"])
        # If the first resource was incorrectly written, different content at version 2 will trigger a conflict.
        after = self.accepted(*self.submit([self.med(0, "2")]))
        self.assertTrue(any(r["id"].startswith("risk-duplicate-") for r in after["risks"]), after)

    def test_unversioned_legacy_then_version_required(self):
        """Preserve legacy updates for unversioned resources; reject unversioned overwrites once a version exists."""
        self.initial(versions=False)
        self.accepted(*self.submit([self.med(0, None, "stopped")]))
        self.accepted(*self.submit([self.med(0, "0")]))
        self.conflict([self.med(0, None, "stopped")], "RESOURCE_VERSION_REQUIRED")


if __name__ == "__main__":
    unittest.main()
