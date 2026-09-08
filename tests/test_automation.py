import os,sys,tempfile,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'src'))
from profile_automation import Decision,matches,processes,validate
class Automation(unittest.TestCase):
    def test_debounce_priority_restore(self):
        d=Decision('music','0');low=(('game','fps',1),);high=(('chat','voice',2),*low)
        self.assertIsNone(d.step(low,'music','0',0))
        self.assertIsNone(d.step(low,'music','0',1.9))
        self.assertEqual(d.step(low,'music','0',2),'fps');d.committed('fps')
        self.assertIsNone(d.step(high,'fps','0',3))
        self.assertEqual(d.step(high,'fps','0',5),'voice');d.committed('voice')
        d.step((),'voice','0',6)
        self.assertEqual(d.step((),'voice','0',8),'music')
    def test_manual_choice_survives_same_game_and_stop(self):
        d=Decision('music','0');group=(('game','fps',1),)
        d.step(group,'music','0',0);d.step(group,'music','0',2);d.committed('fps')
        self.assertIsNone(d.step(group,'balanced','1',3))
        self.assertIsNone(d.step(group,'balanced','1',30))
        self.assertIsNone(d.applied)
        d.step((),'balanced','1',31)
        self.assertIsNone(d.step((),'balanced','1',33))
        self.assertEqual(d.baseline,'balanced')
    def test_manual_same_profile_still_overrides(self):
        d=Decision('music','0');group=(('game','fps',1),)
        d.step(group,'music','0',0);d.step(group,'music','0',2);d.committed('fps')
        d.step(group,'fps','1',3);self.assertTrue(d.hold);self.assertEqual(d.baseline,'fps')
    def test_exact_matches_and_stable_priority(self):
        rules=[{'app':a,'profile':p,'priority':n} for a,p,n in [('a','fps',1),('b','voice',2),('c','surround',2)]]
        self.assertEqual([g[0] for g in matches(validate(rules),{'a','b','c','aaa'})],['b','c','a'])
        self.assertFalse(matches(rules,{'aaa'}))
    def test_native_and_wine_identity_not_arguments(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);proc=root/'123';proc.mkdir();(proc/'exe').symlink_to('/usr/bin/wine-preloader')
            (proc/'cmdline').write_bytes(b'C:\\Games\\match.exe\0other.exe\0')
            names=processes(root)
            self.assertIn('match.exe',names);self.assertIn('wine-preloader',names);self.assertNotIn('other.exe',names)
    def test_reject_invalid_rules(self):
        for r in ([{'app':'a','profile':'unknown','priority':0}],[{'app':'a','profile':'music','priority':True}]):
            with self.assertRaises(ValueError):validate(r)
if __name__=='__main__':unittest.main()
