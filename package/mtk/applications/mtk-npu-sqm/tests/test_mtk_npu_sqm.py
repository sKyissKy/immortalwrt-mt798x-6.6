#!/usr/bin/env python3
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "files" / "mtk-npu-sqm"


class MtkNpuSqmTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.qdma = self.root / "qdma"
        self.hnat = self.root / "hnat"
        self.net = self.root / "net"
        self.bin = self.root / "bin"
        self.uci_store = self.root / "uci.json"
        self.tc_log = self.root / "tc.log"
        self.state_file = self.root / "run" / "mtk_npu_sqm.state"

        for d in (self.qdma, self.hnat, self.net, self.bin):
            d.mkdir(parents=True, exist_ok=True)

        for sch in range(4):
            (self.qdma / f"qdma_sch{sch}").write_text("0 wrr 0\n")
        for q in range(64):
            (self.qdma / f"qdma_txq{q}").write_text(
                "scheduler: 0\nhw resv: 4\nsw resv: 4\npacket count: 10\npacket drop: 1\n"
            )
        (self.hnat / "hook_toggle").write_text("1\n")
        (self.hnat / "qos_toggle").write_text("0\n")
        (self.hnat / "sqm_toggle").write_text("enabled=0 ul_base=16 dl_base=48 queues=16 qos_toggle=0 ul=0 dl=0\n")
        (self.hnat / "wan_if").write_text("eth1\n")
        (self.net / "eth1").mkdir()
        (self.net / "wwan0_1").mkdir()

        self.uci_store.write_text(json.dumps({
            "mtk_npu_sqm.global.enabled": "1",
            "mtk_npu_sqm.global.wan_ifname": "auto",
            "mtk_npu_sqm.global.download": "450000",
            "mtk_npu_sqm.global.upload": "85000",
            "mtk_npu_sqm.global.scheduler": "wrr",
            "mtk_npu_sqm.global.prio_weight": "15",
            "mtk_npu_sqm.global.bulk_weight": "4",
            "mtk_npu_sqm.global.queue_resv": "2",
            "mtk_npu_sqm.global.cake_diffserv": "diffserv4",
            "mtk_npu_sqm.global.cake_ack_filter": "1",
        }))

        uci_mock = self.bin / "uci"
        uci_mock.write_text(f"""#!/usr/bin/env python3
import json, sys
data = json.loads(open({str(self.uci_store)!r}).read())
args = sys.argv[1:]
if '-q' in args:
    args.remove('-q')
if len(args) >= 2 and args[0] == 'get':
    v = data.get(args[1], '')
    if v != '':
        print(v)
        sys.exit(0)
    sys.exit(1)
""")
        uci_mock.chmod(0o755)

        tc_mock = self.bin / "tc"
        tc_mock.write_text(f"""#!/bin/sh
printf '%s\n' "$*" >> {str(self.tc_log)!r}
exit 0
""")
        tc_mock.chmod(0o755)

        ubus_mock = self.bin / "ubus"
        ubus_mock.write_text("""#!/bin/sh
exit 1
""")
        ubus_mock.chmod(0o755)

        self.env = os.environ.copy()
        self.env.update({
            "MTK_SQM_UCI_BIN": str(uci_mock),
            "MTK_SQM_TC_BIN": str(tc_mock),
            "MTK_SQM_UBUS_BIN": str(ubus_mock),
            "MTK_SQM_QDMA_DIR": str(self.qdma),
            "MTK_SQM_HNAT_DIR": str(self.hnat),
            "MTK_SQM_SYS_NET": str(self.net),
            "MTK_SQM_STATE_FILE": str(self.state_file),
        })

    def tearDown(self):
        self.tmp.cleanup()

    def set_uci(self, updates):
        data = json.loads(self.uci_store.read_text())
        data.update(updates)
        self.uci_store.write_text(json.dumps(data))

    def run_cmd(self, *args):
        return subprocess.run(
            ["/bin/sh", str(SCRIPT), *args],
            env=self.env,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_01_full_npu_eth_wan(self):
        self.set_uci({"mtk_npu_sqm.global.wan_ifname": "eth1"})
        res = self.run_cmd("start")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual((self.qdma / "qdma_sch3").read_text().strip(), "1 wrr 450000")
        self.assertEqual((self.qdma / "qdma_sch2").read_text().strip(), "1 wrr 85000")
        self.assertEqual((self.qdma / "qdma_txq48").read_text().strip(), "3 0 0 1 450000 15 2")
        self.assertEqual((self.qdma / "qdma_txq63").read_text().strip(), "3 0 0 1 450000 4 2")
        self.assertEqual((self.qdma / "qdma_txq16").read_text().strip(), "2 0 0 1 85000 15 2")
        self.assertEqual((self.qdma / "qdma_txq31").read_text().strip(), "2 0 0 1 85000 4 2")
        self.assertEqual((self.hnat / "qos_toggle").read_text().strip(), "1")
        self.assertEqual((self.hnat / "sqm_toggle").read_text().strip(), "1")
        if self.tc_log.exists():
            self.assertNotIn("qdisc replace", self.tc_log.read_text())

    def test_02_hybrid_5g_wwan_dl_qdma_ul_cake(self):
        self.set_uci({"mtk_npu_sqm.global.wan_ifname": "wwan0_1"})
        res = self.run_cmd("start")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual((self.qdma / "qdma_sch3").read_text().strip(), "1 wrr 450000")
        self.assertEqual((self.qdma / "qdma_txq48").read_text().strip(), "3 0 0 1 450000 15 2")
        self.assertEqual((self.qdma / "qdma_txq49").read_text().strip(), "3 0 0 1 450000 4 2")
        self.assertEqual((self.qdma / "qdma_sch2").read_text().strip(), "0 wrr 0")
        self.assertEqual((self.hnat / "qos_toggle").read_text().strip(), "1 downlink")
        self.assertEqual((self.hnat / "sqm_toggle").read_text().strip(), "1")
        tc_lines = self.tc_log.read_text().splitlines()
        self.assertIn(
            "qdisc replace dev wwan0_1 root cake bandwidth 85000kbit diffserv4 nat wash split-gso ack-filter",
            tc_lines,
        )

    def test_03_conflict_eqos_mtkhqos_rejected(self):
        self.set_uci({
            "mtk_npu_sqm.global.wan_ifname": "eth1",
            "eqos.config.enabled": "1",
        })
        (self.qdma / "qdma_sch3").write_text("preserve_eqos\n")
        res = self.run_cmd("start")
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("conflict", res.stderr)
        self.assertEqual((self.qdma / "qdma_sch3").read_text().strip(), "preserve_eqos")

    def test_04_stop_resets_qdma_and_cake(self):
        self.set_uci({"mtk_npu_sqm.global.wan_ifname": "wwan0_1"})
        res = self.run_cmd("start")
        self.assertEqual(res.returncode, 0)
        self.tc_log.write_text("")
        res = self.run_cmd("stop")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual((self.hnat / "sqm_toggle").read_text().strip(), "0")
        self.assertEqual((self.hnat / "qos_toggle").read_text().strip(), "0")
        self.assertEqual((self.qdma / "qdma_sch2").read_text().strip(), "0 wrr 0")
        self.assertEqual((self.qdma / "qdma_sch3").read_text().strip(), "0 wrr 0")
        self.assertEqual((self.qdma / "qdma_txq16").read_text().strip(), "0 0 0 0 0 4 4")
        self.assertEqual((self.qdma / "qdma_txq48").read_text().strip(), "0 0 0 0 0 4 4")
        self.assertIn("qdisc del dev wwan0_1 root", self.tc_log.read_text())
        self.assertFalse(self.state_file.exists())


if __name__ == "__main__":
    unittest.main()
