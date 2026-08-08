# Arknights Frame Assistant

This context defines the product language shared while turning this fork into a macOS-specific Arknights Frame Assistant.

## Language

**macOS 实现**:
This fork's sole production target: the Arknights Frame Assistant built for macOS.
_Avoid_: macOS 移植版、双平台版本

**Windows 参考实现**:
The existing Windows/AutoHotkey product retained as a source of product behavior during migration, not as a platform maintained by this fork.
_Avoid_: Windows 正式版、Windows 维护分支

**目标游戏**:
The macOS application `明日方舟.app` whose running game experience the macOS implementation assists.
_Avoid_: `Arknights.exe`、Windows 客户端

**原生游戏环境**:
The official iPhone/iPad `明日方舟.app` running directly on Apple Silicon macOS, outside virtual machines, remote desktops, and compatibility layers.
_Avoid_: 原生 AppKit 游戏、兼容层环境

**首个公开版本**:
The first macOS implementation milestone made available to public users with an explicit supported feature set.
_Avoid_: 完整功能对等版、个人原型

**行为意图**:
The user-visible purpose and expected result preserved from the Windows reference implementation, independent of its platform mechanism or accidental defects.
_Avoid_: 逐行复刻、源码即规格
