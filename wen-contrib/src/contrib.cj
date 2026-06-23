package wen_contrib

// wen-contrib 占位包(P0-J Phase 1)。
//
// Phase 1 仅建立 workspace + 子包骨架,**不迁移**任何中间件。
// Phase 2(留作下个会话)将把 helmet / csrf / cors / auth / logger / requestId
// / methodOverride 从 wen 主包搬到这里,每个 mw 改 `package wen_contrib` +
// `import wen.*` 引用主包符号。届时此占位文件删除。
//
// 当前仅提供一个版本号常量,让本包不为空、能编译。
public let WEN_CONTRIB_VERSION: String = "0.0.0-dev"
