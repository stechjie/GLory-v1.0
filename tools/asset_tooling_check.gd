extends Node

# Regression guard for the two PowerShell asset-delivery scripts.
#
# Why a Godot check policies a .ps1 file: all three defects fixed on 2026-08-20 are
# invisible under normal use. Each one only fires under Windows PowerShell 5.1, or
# only for the 252 non-ASCII asset paths, so the scripts kept "working" for whoever
# ran them under PowerShell 7 with ASCII names. Nothing would have told us they were
# broken until someone actually tried to restore assets on a fresh machine — which
# is exactly the moment the delivery chain has to work.
#
# These are source-text assertions rather than behavioural ones on purpose: running
# the real scripts costs a 2.4 GB repackage, which is far too heavy for a gate.

const CheckHarness := preload("res://tools/CheckHarness.gd")
const CHECK_NAME := "asset_tooling"

const PACKAGE_SCRIPT := "res://tools/package_assets.ps1"
const RESTORE_SCRIPT := "res://tools/restore_assets.ps1"

var _h: RefCounted


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	var package_src := _read(PACKAGE_SCRIPT)
	var restore_src := _read(RESTORE_SCRIPT)
	if package_src.is_empty() or restore_src.is_empty():
		_h.finish(get_tree())
		return
	_check_explicit_utf8_reads(package_src, PACKAGE_SCRIPT)
	_check_explicit_utf8_reads(restore_src, RESTORE_SCRIPT)
	_check_compression_assemblies(package_src)
	_check_zip_entry_name_encoding(package_src)
	_check_guarded_disposes(package_src)
	_h.note("policed %s and %s" % [PACKAGE_SCRIPT.get_file(), RESTORE_SCRIPT.get_file()])
	_h.finish(get_tree())


# Bug 1. Windows PowerShell 5.1 decodes a BOM-less file with the ANSI codepage, so
# 云羽鹰.png is read as äº‘ç¾½é¹°.png and the recomputed inventory hash stops matching
# the manifest. PowerShell 7 defaults to UTF-8, which is why this went unnoticed.
func _check_explicit_utf8_reads(source: String, label: String) -> void:
	var lines := source.split("\n")
	var reads := 0
	for i in lines.size():
		var line := str(lines[i])
		if not line.contains("Get-Content"):
			continue
		reads += 1
		_h.expect(line.contains("-Encoding UTF8"),
			"getcontent_no_encoding",
			"%s 第 %d 行的 Get-Content 缺 -Encoding UTF8，PowerShell 5.1 会按 ANSI 解码中文路径" % [label, i + 1])
	_h.expect(reads > 0, "no_getcontent", "%s 里一个 Get-Content 都没有，断言可能已失效" % label)


# Bug 2. ZipArchive lives in System.IO.Compression; ZipFile lives in
# System.IO.Compression.FileSystem. Loading only the latter makes ZipArchive::new
# throw "Unable to find type" under 5.1.
func _check_compression_assemblies(source: String) -> void:
	if not source.contains("IO.Compression.ZipArchive"):
		return
	_h.expect(source.contains("Add-Type -AssemblyName System.IO.Compression\n")
			or source.contains("Add-Type -AssemblyName System.IO.Compression\r"),
		"missing_compression_assembly",
		"用到 ZipArchive 就必须 Add-Type System.IO.Compression，只加 .FileSystem 在 5.1 下会找不到类型")
	_h.expect(source.contains("Add-Type -AssemblyName System.IO.Compression.FileSystem"),
		"missing_filesystem_assembly", "缺 Add-Type System.IO.Compression.FileSystem")


# Bug 3. Passing an explicit entryNameEncoding makes .NET write the names in it but
# leave the zip language-encoding (EFS) flag clear, so a reader without an explicit
# encoding falls back to CP437 and every non-ASCII entry name comes back as mojibake.
# With $null, .NET sets the flag for non-ASCII names and the round trip is symmetric.
func _check_zip_entry_name_encoding(source: String) -> void:
	var marker := "ZipArchiveMode]::Create"
	var at := source.find(marker)
	_h.expect(at >= 0, "no_ziparchive_create", "找不到 ZipArchive 的 Create 调用，断言可能已失效")
	if at < 0:
		return
	var line_end := source.find("\n", at)
	var line := source.substr(at, maxi(0, line_end - at))
	_h.expect(line.contains("$null"),
		"zip_entry_encoding",
		"ZipArchive 的 entryNameEncoding 必须传 $null；传 UTF8 会不设 EFS 标志位，252 个中文条目名会变乱码")
	_h.expect(not line.contains("utf8NoBom"),
		"zip_entry_encoding_utf8",
		"ZipArchive 的 entryNameEncoding 又被改回显式编码了")


# The original finally called $zip.Dispose() unguarded. When construction failed,
# StrictMode threw on the undefined variable before $zipStream.Dispose() could run,
# leaving a locked 0-byte file whose cleanup failure then masked the real error.
func _check_guarded_disposes(source: String) -> void:
	for variable in ["$zip", "$zipStream"]:
		_h.expect(source.contains("if ($null -ne %s) { %s.Dispose() }" % [variable, variable]),
			"unguarded_dispose",
			"%s.Dispose() 必须有空值守卫，否则构造失败时会掩盖真正的错误并泄漏文件句柄" % variable)


func _read(path: String) -> String:
	var source := FileAccess.get_file_as_string(path)
	_h.expect(not source.is_empty(), "source_missing", "读不到 %s" % path)
	return source
