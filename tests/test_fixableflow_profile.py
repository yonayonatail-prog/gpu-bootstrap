from pathlib import Path
import unittest

import orchestrator as o


class FixableFlowProfileTests(unittest.TestCase):
    def test_fixableflow_plan_loads_with_pinned_nodes(self):
        runtime = Path('/tmp/gpu-bootstrap-fixableflow-plan')
        profile, assets, nodes = o.load_plan(o.HERE, 'fixableflow', runtime)

        self.assertEqual(profile['name'], 'fixableflow')
        self.assertEqual(assets, [])
        self.assertEqual(
            set(nodes),
            {
                'ComfyUI-fixableflow',
                'ComfyUI-FreeMemory',
                'ComfyUI_essentials',
                'ComfyUI-FramePackWrapper_Plus',
            },
        )
        self.assertGreaterEqual(profile['disk']['install_budget_gib'], 80)
        for node in nodes.values():
            self.assertRegex(node['revision'], r'^[0-9a-f]{40}$')


if __name__ == '__main__':
    unittest.main()
