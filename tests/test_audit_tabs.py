"""Check the page structure of audit tasks and audit cases."""
import unittest
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

class PageIndex(HTMLParser):
    """Record page tags, panels and their ownership."""
    def __init__(self):
        super().__init__(); self.stack=[]; self.by_id={}
    def handle_starttag(self, tag, attrs):
        props=dict(attrs); identity=props.get('id'); parent=next((x for x in reversed(self.stack) if x),None)
        if identity: self.by_id[identity]=(tag,props,parent)
        if tag not in {'input','br','meta','link','img','hr','source','wbr'}: self.stack.append(identity)
    def handle_endtag(self, tag):
        if tag not in {'input','br','meta','link','img','hr','source','wbr'} and self.stack: self.stack.pop()

class AuditTabsTest(unittest.TestCase):
    def test_tasks_and_cases_have_distinct_linked_panels(self):
        """The two tabs must link to different panels; task and case lists are not mixed."""
        dom=PageIndex(); dom.feed((ROOT/'web/index.html').read_text())
        for tab,panel in [('auditTasksTab','page-cases'),('auditCasesTab','page-case-list')]:
            self.assertIn(tab,dom.by_id)
            self.assertIn(panel,dom.by_id)
            self.assertEqual(dom.by_id[tab][1].get('aria-controls'),panel)
        self.assertEqual(dom.by_id['workflowTasks'][2],'page-cases')
        self.assertEqual(dom.by_id['caseList'][2],'page-case-list')
