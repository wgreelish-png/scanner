import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('configure_signing', Path(__file__).with_name('configure_signing.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SigningTests(unittest.TestCase):
    def test_create_repeat_and_protect_existing(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'Config' / 'Signing.local.xcconfig'
            self.assertTrue(module.configure('ABCDEFGHIJ', output))
            self.assertFalse(module.configure('ABCDEFGHIJ', output))
            with self.assertRaises(ValueError):
                module.configure('0123456789', output)
            self.assertIn('ABCDEFGHIJ', output.read_text())

    def test_extract_and_reject_ambiguous_or_invalid(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory) / 'project.pbxproj'
            project.write_text('DEVELOPMENT_TEAM = ABCDEFGHIJ;\nDEVELOPMENT_TEAM = "ABCDEFGHIJ";')
            self.assertEqual(module.team_from_project(project), 'ABCDEFGHIJ')
            project.write_text('DEVELOPMENT_TEAM = ABCDEFGHIJ;\nDEVELOPMENT_TEAM = 0123456789;')
            with self.assertRaises(ValueError): module.team_from_project(project)
            with self.assertRaises(ValueError): module.configure('invalid', Path(directory) / 'local')


if __name__ == '__main__':
    unittest.main()
