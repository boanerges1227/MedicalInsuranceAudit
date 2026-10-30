"""Verify that the AI overview summarizes registered investigations without starting a model."""
import unittest
from test_demo import call

class AgentObservabilityTest(unittest.TestCase):
    def test_summary_counts_and_unknown_usage_are_explicit(self):
        status, data = call('/api/agent-summary')
        self.assertEqual(status, 200)
        self.assertEqual(data['scope'], 'recorded_agent_runs')
        self.assertLessEqual(data['modelStarted'], data['total'])
        self.assertLessEqual(data['usageRecorded'], data['total'])
        self.assertIn('durationRecorded', data)
        self.assertIn('inputTokens', data)
        self.assertIn('outputTokens', data)
