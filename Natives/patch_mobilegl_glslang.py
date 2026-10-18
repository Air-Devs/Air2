#!/usr/bin/env python3
"""Patch MobileGL's vendored glslang to stop crashing on null swizzle operands.

Root cause, confirmed at instruction level (libMobileGL.dylib @ 0xae4514):

    TGlslangToSpvTraverser::convertSwizzle(const TIntermAggregate&, vector<unsigned>&)
      +0x10:  ldur x0, [x29,#-0x10]     ; x0 = the TIntermAggregate reference
      +0x14:  ldr  x8, [x0]             ; <-- SIGSEGV, x0 == nullptr
      +0x18:  ldr  x8, [x8, #0x1a0]
      +0x1c:  blr  x8                   ; getSequence()

Both call sites feed the result of getAsAggregate() straight into a reference:

    convertSwizzle(*node->getRight()->getAsAggregate(), swizzle);                  (visitBinary, EOpVectorSwizzle)
    convertSwizzle(*node.getAsBinaryNode()->getRight()->getAsAggregate(), swizzle);(createInvertedSwizzle)

When the swizzle's right operand is not a TIntermAggregate, getAsAggregate()
returns nullptr, the dereference binds a reference to null, and the very first
thing convertSwizzle does -- getSequence() -- faults. Minecraft 26.3 shaders
reach this path on iOS; Android is unaffected because SDL hands MobileGL an ES
context there, so a different shader dialect is generated.

The parser normally builds the swizzle operand as a TIntermAggregate of constant
unions, but a single-component swizzle can also arrive as a bare
TIntermConstantUnion, so that shape is handled explicitly rather than merely
guarded -- otherwise the guard would trade a crash for wrong SPIR-V.

The identical unguarded pattern exists in TParseContext::lValueErrorCheck
(ParseHelper.cpp, EOpVectorSwizzle), which is reached for l-value swizzles and
would crash the same way once the parse path is exercised.

This script is idempotent and aborts loudly if any anchor is missing, so a
future glslang update cannot silently leave the bug in place.
"""

import os
import sys

GLSLANG_TO_SPV = os.path.join(
    "3rdparty", "glslang", "SPIRV", "GlslangToSpv.cpp")
PARSE_HELPER = os.path.join(
    "3rdparty", "glslang", "glslang", "MachineIndependent", "ParseHelper.cpp")

MARKER = "convertSwizzleSafe"


class PatchError(Exception):
    pass


def read(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return handle.read()
    except IOError as exc:
        raise PatchError("cannot read %s: %s" % (path, exc))


def write(path, text):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def replace_once(text, old, new, path, label):
    # Check the patched form first: several anchors are prefixes of their
    # replacement (the declaration gains a sibling line), so testing the
    # unpatched form first would match again and duplicate the insertion.
    if new in text:
        return text, "already applied"
    if old not in text:
        raise PatchError(
            "anchor not found for %s in %s; glslang source layout changed"
            % (label, path))
    return text.replace(old, new, 1), "applied"


# --- GlslangToSpv.cpp -------------------------------------------------------

# 1. Declare the safe helper next to convertSwizzle.
DECL_OLD = """    void convertSwizzle(const glslang::TIntermAggregate&, std::vector<unsigned>& swizzle);
"""
DECL_NEW = """    void convertSwizzle(const glslang::TIntermAggregate&, std::vector<unsigned>& swizzle);
    bool convertSwizzleSafe(const glslang::TIntermTyped* right, std::vector<unsigned>& swizzle,
        const char* context);
"""

# 2. Harden convertSwizzle itself and add the helper.
DEF_OLD = """// Convert a glslang AST swizzle node to a swizzle vector for building SPIR-V.
void TGlslangToSpvTraverser::convertSwizzle(const glslang::TIntermAggregate& node, std::vector<unsigned>& swizzle)
{
    const glslang::TIntermSequence& swizzleSequence = node.getSequence();
    for (int i = 0; i < (int)swizzleSequence.size(); ++i)
        swizzle.push_back(swizzleSequence[i]->getAsConstantUnion()->getConstArray()[0].getIConst());
}
"""
DEF_NEW = """// Convert a glslang AST swizzle node to a swizzle vector for building SPIR-V.
void TGlslangToSpvTraverser::convertSwizzle(const glslang::TIntermAggregate& node, std::vector<unsigned>& swizzle)
{
    const glslang::TIntermSequence& swizzleSequence = node.getSequence();
    for (int i = 0; i < (int)swizzleSequence.size(); ++i) {
        const glslang::TIntermTyped* selector = swizzleSequence[i]->getAsTyped();
        const glslang::TIntermConstantUnion* constant =
            selector ? selector->getAsConstantUnion() : nullptr;
        // getConstArray() returns a reference, never null; its backing vector
        // can be unallocated, which size() reports as 0.
        if (constant == nullptr || constant->getConstArray().size() == 0)
            continue;
        swizzle.push_back(constant->getConstArray()[0].getIConst());
    }
}

// Resolve the right operand of a glslang swizzle node into a swizzle vector.
//
// The operand is normally a TIntermAggregate of constant unions, but a
// single-component swizzle can also arrive as a bare TIntermConstantUnion.
// Binding a null aggregate to convertSwizzle()'s reference parameter crashes on
// the first getSequence() call, so both shapes are handled here and anything
// else degrades to "missing functionality" instead of a segfault.
bool TGlslangToSpvTraverser::convertSwizzleSafe(const glslang::TIntermTyped* right,
    std::vector<unsigned>& swizzle, const char* context)
{
    swizzle.clear();
    (void)context;

    if (right == nullptr) {
        logger->missingFunctionality("null swizzle operand");
        return false;
    }

    if (const glslang::TIntermAggregate* aggregate = right->getAsAggregate()) {
        convertSwizzle(*aggregate, swizzle);
        if (swizzle.empty())
            logger->missingFunctionality("empty swizzle operand");
        return !swizzle.empty();
    }

    if (const glslang::TIntermConstantUnion* constant = right->getAsConstantUnion()) {
        if (constant->getConstArray().size() > 0) {
            swizzle.push_back(constant->getConstArray()[0].getIConst());
            return true;
        }
    }

    logger->missingFunctionality("unsupported swizzle operand");
    return false;
}
"""

# 3. visitBinary, case EOpVectorSwizzle.
SITE_OLD = """            convertSwizzle(*node->getRight()->getAsAggregate(), swizzle);
"""
SITE_NEW = """            if (!convertSwizzleSafe(node->getRight(), swizzle, "EOpVectorSwizzle")) {
                logger->missingFunctionality("vector swizzle operand");
                return true;
            }
"""

# 4. createInvertedSwizzle.
INVERTED_OLD = """    std::vector<unsigned> swizzle;
    convertSwizzle(*node.getAsBinaryNode()->getRight()->getAsAggregate(), swizzle);
    return builder.createRvalueSwizzle(precision, convertGlslangToSpvType(node.getType()), parentResult, swizzle);
"""
INVERTED_NEW = """    std::vector<unsigned> swizzle;
    const glslang::TIntermBinary* binaryNode = node.getAsBinaryNode();
    if (binaryNode == nullptr || !convertSwizzleSafe(binaryNode->getRight(), swizzle, "createInvertedSwizzle")) {
        logger->missingFunctionality("inverted swizzle operand");
        return parentResult;
    }
    return builder.createRvalueSwizzle(precision, convertGlslangToSpvType(node.getType()), parentResult, swizzle);
"""

# --- ParseHelper.cpp --------------------------------------------------------

# 5. Guard against a null node at function entry.
LVALUE_ENTRY_OLD = """bool TParseContext::lValueErrorCheck(const TSourceLoc& loc, const char* op, TIntermTyped* node)
{
    TIntermBinary* binaryNode = node->getAsBinaryNode();
"""
LVALUE_ENTRY_NEW = """bool TParseContext::lValueErrorCheck(const TSourceLoc& loc, const char* op, TIntermTyped* node)
{
    if (node == nullptr)
        return true;

    TIntermBinary* binaryNode = node->getAsBinaryNode();
"""

# 6. Guard the unguarded getAsAggregate() dereference for EOpVectorSwizzle.
LVALUE_OLD = """                TIntermTyped* rightNode = binaryNode->getRight();
                TIntermAggregate *aggrNode = rightNode->getAsAggregate();

                for (TIntermSequence::iterator p = aggrNode->getSequence().begin();
                                               p != aggrNode->getSequence().end(); p++) {
                    int value = (*p)->getAsTyped()->getAsConstantUnion()->getConstArray()[0].getIConst();
"""
LVALUE_NEW = """                TIntermTyped* rightNode = binaryNode->getRight();
                TIntermAggregate *aggrNode = rightNode ? rightNode->getAsAggregate() : nullptr;
                if (aggrNode == nullptr)
                    return errorReturn;

                for (TIntermSequence::iterator p = aggrNode->getSequence().begin();
                                               p != aggrNode->getSequence().end(); p++) {
                    const TIntermConstantUnion* constantNode = (*p)->getAsTyped()
                        ? (*p)->getAsTyped()->getAsConstantUnion() : nullptr;
                    if (constantNode == nullptr || constantNode->getConstArray().size() == 0)
                        continue;
                    int value = constantNode->getConstArray()[0].getIConst();
"""


def patch_glslang_to_spv(root):
    path = os.path.join(root, GLSLANG_TO_SPV)
    text = read(path)
    for old, new, label in (
        (DECL_OLD, DECL_NEW, "convertSwizzleSafe declaration"),
        (DEF_OLD, DEF_NEW, "convertSwizzle definition"),
        (SITE_OLD, SITE_NEW, "visitBinary swizzle site"),
        (INVERTED_OLD, INVERTED_NEW, "createInvertedSwizzle site"),
    ):
        text, status = replace_once(text, old, new, GLSLANG_TO_SPV, label)
        print("  %-38s %s" % (label, status))
    write(path, text)


def patch_parse_helper(root):
    path = os.path.join(root, PARSE_HELPER)
    text = read(path)
    for old, new, label in (
        (LVALUE_ENTRY_OLD, LVALUE_ENTRY_NEW, "lValueErrorCheck null node"),
        (LVALUE_OLD, LVALUE_NEW, "lValueErrorCheck swizzle"),
    ):
        text, status = replace_once(text, old, new, PARSE_HELPER, label)
        print("  %-38s %s" % (label, status))
    write(path, text)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    glslang_dir = os.path.join(root, "3rdparty", "glslang")
    if not os.path.isdir(glslang_dir):
        print("MobileGL source not found at %s, skipping glslang patch" % root)
        return 0

    print("Patching vendored glslang in %s" % root)
    patch_glslang_to_spv(root)
    patch_parse_helper(root)

    patched = read(os.path.join(root, GLSLANG_TO_SPV))
    if MARKER not in patched:
        raise PatchError("post-condition failed: %s missing after patch" % MARKER)
    print("glslang swizzle patch verified")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except PatchError as error:
        print("ERROR: %s" % error, file=sys.stderr)
        sys.exit(1)
