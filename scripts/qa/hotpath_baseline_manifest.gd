extends RefCounted
# Generated source identities, refreshed before packing.
const DATA: Dictionary = {
	"baseline_commit": "ad76ec05fd564201c3b27eaa2d6f3fafbfe26b9f",
	"scope": "QA-only isolated script CPU hotspots; no pixel rendering, frame-rate, energy or thermal claims",
	"reference_strategy": "Exact git-show functions; shared current infrastructure; static helper renamed only",
	"shared_registry_condition": "Both arms use current UnitActorRegistry, including freed-instance validity-order fix",
	"frozen_functions": [
		{
			"source": "scenes/battle/BattleRenderer.gd",
			"function": "_visual_id",
			"original_function_sha256": "6c49fab32c10cb0570836d89ddad591ca34437ffaa822773e6cba146ca5527c1",
			"emitted_function_sha256": "6c49fab32c10cb0570836d89ddad591ca34437ffaa822773e6cba146ca5527c1",
			"frozen_file": "scripts/qa/hotpath_baseline_vfx.gd"
		},
		{
			"source": "scenes/battle/BattleVfx.gd",
			"function": "_collect_vfx_units",
			"original_function_sha256": "a831b96b30a17c8e59118e7db449d0d260d6416068fea2f5245e98c264069c1c",
			"emitted_function_sha256": "a831b96b30a17c8e59118e7db449d0d260d6416068fea2f5245e98c264069c1c",
			"frozen_file": "scripts/qa/hotpath_baseline_vfx.gd"
		},
		{
			"source": "scenes/battle/BattleVfx.gd",
			"function": "_unit_vfx_position",
			"original_function_sha256": "7fab5e33dbff7e5d6a11a9d21b0853a7680cbfba64e0b948966a74517aab8fdd",
			"emitted_function_sha256": "7fab5e33dbff7e5d6a11a9d21b0853a7680cbfba64e0b948966a74517aab8fdd",
			"frozen_file": "scripts/qa/hotpath_baseline_vfx.gd"
		},
		{
			"source": "scenes/battle/StatusVFXController.gd",
			"function": "update_from_fighter",
			"original_function_sha256": "0ad8df115dae4d99a37120ec20a9c0db3fe778111c1be285a99275c510c49e61",
			"emitted_function_sha256": "56e292983876371efffa26c0ffd38f57ed0aa07c2e3816d74c56d41d5d10e897",
			"frozen_file": "scripts/qa/hotpath_baseline_status.gd"
		},
		{
			"source": "scenes/battle/StatusVFXController.gd",
			"function": "active_poison_layers",
			"original_function_sha256": "546111e0e1718a6be826fcb0c737928cdee4e5e66b1014967c0d71d597b85a08",
			"emitted_function_sha256": "4a9b53682320269e5eaea37033cf808c1cb192f7cd0986652f4802f556a8b9e2",
			"frozen_file": "scripts/qa/hotpath_baseline_status.gd"
		}
	],
	"baseline_sources": {
		"scenes/battle/BattleRenderer.gd": "c2f9e6ccee2ac26bf366e6fc06252544eda68982702a62da8dcbf7bf7a7a1b73",
		"scenes/battle/BattleVfx.gd": "2a4dfe1d132d63f9bb82f84011737eefbb01fbfb6f5c19a88e31791a2bbe4ee2",
		"scenes/battle/StatusVFXController.gd": "e0e7a9577983e2af3c399c21727293d4daa2ac4480ad2af5b855ac3464aeb067"
	},
	"current_sources": {
		"scripts/qa/hotpath_baseline_vfx.gd": "7157cdc21199b71e6209eabd835caf08e275e5e2bd47bb76a65ebfafdbfccfd7",
		"scripts/qa/hotpath_baseline_status.gd": "bfa6375874a3c1b31610b4486bb2b2cc41d5e40a582350ab34418e0e951281f9",
		"scenes/battle/BattleRenderer.gd": "1d5c9b9bbda6fd6dc2f9071672b6660ea9cd3e7b980c0403eb5827056892b64c",
		"scenes/battle/BattleVfx.gd": "bff19790c44974eac46faa984402e632b0b561c3b51d07ca27464478a418b6f1",
		"scenes/battle/StatusVFXController.gd": "8758e90187ce40d54f755d27c6f7521e1923e80898e870ba56a248b09cd7ff4d",
		"effects/runtime/presentation/UnitActorRegistry.gd": "06f22084f5c8ce4fa906cf1200ebbeb553063757df81c7ffe4d77812b11cfd18",
		"scripts/qa/FixedBattleFixture.gd": "70cb8bd3b6604ce2d5fb5b910cd1719897ab8da708ebc4f49d816df5d26ab5fa",
		"scripts/battle/BattleSimulator.gd": "4faff87dfb7e228e6f0cb7d03e2f604e0c885bdf28bb640e994466bc35e72fb9",
		"scenes/battle/BattleScreen.gd": "a2d512ce57c4ece3214eff8ba3aadbc59187dfb9fdabfb31541ab0672eb383d3",
		"scripts/qa/ReplayDigest.gd": "e95f3f9286b083b0073b80fe300eb971ce940d4df3a32ed52e94c0bfd76df021",
		"scripts/qa/battle_hotpath_benchmark.gd": "5a49732f5d15420de2e48509caf4a9e8056e1890c5aa0c33b0822ecf5d56bb22",
		"project.godot": "8b9ac7ad2504f08e65f7c1b5fb572c9042032dcd0255964ecb38706d1d915779"
	},
	"working_tree_head": "ad76ec05fd564201c3b27eaa2d6f3fafbfe26b9f"
}
