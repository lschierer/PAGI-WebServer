// Generates the Spectrum custom-property layer from @adobe/spectrum-tokens.
//
// WHY. The sites used to get this layer as prebuilt CSS from @spectrum-css/tokens. That
// package's last release, 16.0.2, was generated from
// @adobe/spectrum-tokens@0.0.0-s2-foundations-20241121221506 - a November 2024
// prerelease - and adobe/spectrum-css has had no substantive commit on main since April
// 2026. @adobe/spectrum-tokens meanwhile ships from adobe/spectrum-design-data and is
// still moving. Against 15.4.1 the prebuilt layer is short 917 properties and still
// carries 150 that the token source has dropped. Generating from the JSON closes that
// gap and puts the token version under the site's own control, in its package.json.
//
// The token package ships JSON only - dist/json/variables.json plus the DTCG sources in
// src/ - so there is nothing to @import. This file is the missing build step.
//
// WHAT IT DOES NOT DO. It emits foundations and whatever component tokens the source
// still carries. It does not replace the @spectrum-css/* component RULES, which a site
// still imports. The handful of properties those packages read and this layer cannot
// supply lives in spectrum-token-shim.ts, deliberately separate and deliberately
// shrinking. See that file.
//
// OUTPUT SHAPE. Deliberately identical to @spectrum-css/tokens: one block per mode,
// selectors .spectrum / .spectrum--light / .spectrum--dark / .spectrum--medium /
// .spectrum--large. That is what the sites' templates already set on <html>, so the
// swap is an @import change and nothing more.

import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { createRequire } from "node:module";

import {
  AUTHORED_SUPPLEMENTS,
  LEGACY_COMPONENT_TOKENS,
  MODE_SELECTORS,
  type TokenMode,
} from "./spectrum-token-shim.ts";

/**
 * A node in variables.json. `sets` keys are mode names; `ref` is a {token-name}.
 *
 * `value` is not always a string. Four kinds appear in 15.4.1:
 *   - string, the common case ("8px", "rgb(0, 0, 0)")
 *   - number, for unitless ratios - and these matter here, because
 *     --spectrum-body-line-height and --spectrum-heading-line-height are among them
 *   - array, for the four multi-layer drop-shadow-* tokens
 *   - object, for the fifteen component-*-{bold,medium,regular} typography sets
 * The last two have no single-custom-property representation and are skipped; see
 * `skippedComposites` in the build summary.
 */
interface TokenNode {
  value?: string | number | unknown[] | Record<string, unknown>;
  /**
   * `"{gray-100}"` for an ordinary alias, but composite-shaped for the composite
   * tokens: the shadow tokens carry an array of layer objects whose `color` is itself a
   * reference, and the typography sets carry an object of per-field references. Only the
   * string form is an alias this generator can emit.
   */
  ref?: string | unknown[] | Record<string, unknown>;
  uuid?: string;
  sets?: Record<string, TokenNode>;
}

type TokenFile = Record<string, TokenNode>;

/** Which set key feeds which emitted mode block. */
const COLOR_SETS: ReadonlyArray<readonly [string, TokenMode]> = [
  ["light", "light"],
  ["dark", "dark"],
];
const SCALE_SETS: ReadonlyArray<readonly [string, TokenMode]> = [
  // Spectrum's "medium" scale is the desktop metric set and "large" is the touch one.
  ["desktop", "medium"],
  ["mobile", "large"],
];

export interface BuildSpectrumTokensOptions {
  /** Where to write the stylesheet, relative to the site root. */
  outFile: string;
  /**
   * Site root used to resolve @adobe/spectrum-tokens. The SITE owns the token version,
   * the framework owns only this transform, so resolution starts from the site exactly
   * as stylelint.config.js does.
   */
  siteRoot?: string;
}

/**
 * The token a node aliases, or undefined when it is not a plain alias.
 * `"{gray-100}"` -> `"gray-100"`; composite refs yield undefined.
 */
function aliasTarget(node: TokenNode): string | undefined {
  if (typeof node.ref !== "string") return undefined;
  return node.ref.replace(/^\{/, "").replace(/\}$/, "");
}

function cssName(token: string): string {
  return `--spectrum-${token}`;
}

/**
 * Font weights are stored as design names, not CSS values: the source says
 * `"regular"` and `"extra-bold"` where CSS needs 400 and 800. Only `bold` is a real CSS
 * keyword; `regular`, `light`, `medium`, `extra-bold` and `black` are not, so emitting
 * them verbatim yields `font-weight: regular`, which is invalid and drops every weight
 * in the project back to whatever it inherits. @spectrum-css/tokens did this mapping in
 * its Style Dictionary config, which is why it is easy to miss when reading the JSON.
 */
const FONT_WEIGHT_VALUES: Record<string, string> = {
  light: "300",
  regular: "400",
  medium: "500",
  bold: "700",
  "extra-bold": "800",
  black: "900",
};

/**
 * A token value as CSS text, or undefined when it has no single-property form.
 * Numbers become bare numbers, which is what the unitless ratio tokens want.
 */
function scalarValue(
  token: string,
  value: TokenNode["value"],
): string | undefined {
  if (typeof value === "number") return String(value);
  if (typeof value !== "string") return undefined;

  if (token.endsWith("font-weight")) {
    const mapped = FONT_WEIGHT_VALUES[value];
    if (mapped !== undefined) return mapped;
  }

  return value;
}

/**
 * Resolve a token to a literal value in one mode context, following refs and sets.
 *
 * Needed only for the -rgb/-opacity companions: those have to be real numbers, so an
 * alias chain has to be walked to the end even though the main declaration emits a
 * var() and stops. Returns undefined when no literal exists for this context, which is
 * normal - not every token is defined in every mode.
 */
function resolveLiteral(
  tokens: TokenFile,
  token: string,
  scheme: string,
  scale: string,
  seen = new Set<string>(),
): string | undefined {
  if (seen.has(token)) return undefined; // a cycle in the data, not our problem to fix
  seen.add(token);

  const walk = (node: TokenNode | undefined): string | undefined => {
    if (!node) return undefined;
    // A node's own sets win over its value: the value on a ref'd node is a convenience
    // copy that may not correspond to the mode being asked about.
    if (node.sets) {
      const picked = node.sets[scheme] ?? node.sets[scale];
      const fromSet = walk(picked);
      if (fromSet !== undefined) return fromSet;
    }
    const alias = aliasTarget(node);
    if (alias !== undefined)
      return resolveLiteral(tokens, alias, scheme, scale, seen);
    return scalarValue(token, node.value);
  };

  return walk(tokens[token]);
}

/** `rgb(1, 2, 3)` / `rgba(1, 2, 3, .5)` / `#abc` -> channels, else undefined. */
function parseColor(
  value: string,
): { channels: string; alpha?: string } | undefined {
  const fn =
    /^rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)\s*(?:[,/]\s*([\d.%]+)\s*)?\)$/i.exec(
      value.trim(),
    );
  if (fn) {
    return {
      channels: `${fn[1]}, ${fn[2]}, ${fn[3]}`,
      alpha: fn[4],
    };
  }

  const hex = /^#([\da-f]{3}|[\da-f]{4}|[\da-f]{6}|[\da-f]{8})$/i.exec(
    value.trim(),
  );
  if (!hex) return undefined;

  const digits = hex[1];
  const short = digits.length <= 4;
  const pair = (i: number): string => {
    const raw = short ? digits[i]!.repeat(2) : digits.slice(i * 2, i * 2 + 2);
    return String(Number.parseInt(raw, 16));
  };
  const hasAlpha = digits.length === 4 || digits.length === 8;

  return {
    channels: `${pair(0)}, ${pair(1)}, ${pair(2)}`,
    alpha: hasAlpha
      ? String(
          Number.parseInt(
            short ? digits[3]!.repeat(2) : digits.slice(6, 8),
            16,
          ) / 255,
        )
      : undefined,
  };
}

/** The declarations for one emitted mode block, property -> value. */
type Block = Map<string, string>;

function emit(
  blocks: Map<TokenMode, Block>,
  mode: TokenMode,
  prop: string,
  value: string,
): void {
  let block = blocks.get(mode);
  if (!block) {
    block = new Map();
    blocks.set(mode, block);
  }
  block.set(prop, value);
}

/**
 * Add the -rgb (and -opacity) companions @spectrum-css/tokens derives with
 * @spectrum-tools/postcss-rgb-mapping. Component CSS composes translucent washes as
 * `rgba(var(--spectrum-gray-900-rgb), 0.06)`, so a colour token that lacks its
 * companion breaks those rules rather than merely looking different.
 */
function emitColorCompanions(
  blocks: Map<TokenMode, Block>,
  mode: TokenMode,
  tokens: TokenFile,
  token: string,
  scheme: string,
  scale: string,
): void {
  const literal = resolveLiteral(tokens, token, scheme, scale);
  if (literal === undefined) return;
  const parsed = parseColor(literal);
  if (!parsed) return;

  emit(blocks, mode, `${cssName(token)}-rgb`, parsed.channels);
  if (parsed.alpha !== undefined) {
    emit(blocks, mode, `${cssName(token)}-opacity`, parsed.alpha);
  }
}

/**
 * Turn one token into declarations across the mode blocks it applies to.
 * Returns true when the token had a composite value and was skipped.
 */
function emitToken(
  blocks: Map<TokenMode, Block>,
  tokens: TokenFile,
  token: string,
  node: TokenNode,
): boolean {
  const prop = cssName(token);

  // A top-level ref means a plain alias. Such a node often also carries `sets` - that is
  // the REFERENT's mode expansion showing through the resolved JSON, not modes of this
  // token - so the ref has to be tested first or every alias would be misread as
  // mode-dependent and duplicated into every block.
  const alias = aliasTarget(node);
  if (alias !== undefined) {
    emit(blocks, "global", prop, `var(${cssName(alias)})`);
    emitColorCompanions(blocks, "global", tokens, token, "light", "desktop");
    return false;
  }

  if (node.sets) {
    let skipped = false;
    for (const [setKey, mode] of [...COLOR_SETS, ...SCALE_SETS]) {
      const set = node.sets[setKey];
      if (!set) continue;

      const setAlias = aliasTarget(set);
      const value =
        setAlias !== undefined
          ? `var(${cssName(setAlias)})`
          : scalarValue(token, set.value);
      if (value === undefined) {
        // Either no value for this mode at all, or a composite. Only the latter counts
        // as skipped work; the former is ordinary sparseness.
        skipped ||= set.value !== undefined;
        continue;
      }

      emit(blocks, mode, prop, value);

      const isColor = COLOR_SETS.some(([key]) => key === setKey);
      emitColorCompanions(
        blocks,
        mode,
        tokens,
        token,
        isColor ? setKey : "light",
        isColor ? "desktop" : setKey,
      );
    }
    // `wireframe` is intentionally dropped: it is a Spectrum-internal mode with no
    // .spectrum--* selector and no consumer here.
    return skipped;
  }

  const value = scalarValue(token, node.value);
  if (value !== undefined) {
    emit(blocks, "global", prop, value);
    emitColorCompanions(blocks, "global", tokens, token, "light", "desktop");
    return false;
  }

  return node.value !== undefined;
}

function mergeShim(
  blocks: Map<TokenMode, Block>,
  shim: Partial<Record<TokenMode, Record<string, string>>>,
): void {
  for (const [mode, declarations] of Object.entries(shim) as Array<
    [TokenMode, Record<string, string>]
  >) {
    for (const [prop, value] of Object.entries(declarations)) {
      emit(blocks, mode, prop, value);
    }
  }
}

export async function buildSpectrumTokens(
  options: BuildSpectrumTokensOptions,
): Promise<void> {
  const siteRoot = options.siteRoot ?? process.cwd();
  const siteManifestPath = path.join(siteRoot, "package.json");

  // Opt in by DECLARING the dependency, not merely by being able to resolve it. A site
  // can resolve @adobe/spectrum-tokens transitively without wanting a token layer -
  // originalFiction reaches it through @adobe/spectrum-design-data-mcp - and generating
  // an unreferenced 5000-property stylesheet into such a site's source tree is not a
  // favour. Declaring the dependency is the unambiguous signal.
  const siteManifest = JSON.parse(
    await fs.readFile(siteManifestPath, "utf8"),
  ) as {
    dependencies?: Record<string, string>;
    devDependencies?: Record<string, string>;
  };
  const declared =
    siteManifest.dependencies?.["@adobe/spectrum-tokens"] ??
    siteManifest.devDependencies?.["@adobe/spectrum-tokens"];
  if (declared === undefined) {
    console.log(
      "· No @adobe/spectrum-tokens in package.json; skipping the Spectrum token layer.",
    );
    return;
  }

  const requireFromSite = createRequire(siteManifestPath);

  // Resolved via the dist entry rather than package.json: the token package's exports
  // map publishes "./dist/*" but not "./package.json", so asking for the manifest by
  // specifier throws ERR_PACKAGE_PATH_NOT_EXPORTED. The manifest is then read off disk
  // from the resolved location, which the exports map does not police.
  //
  // Declared but not installed is a real error - the site asked for this - so no catch.
  const variablesPath = requireFromSite.resolve(
    "@adobe/spectrum-tokens/dist/json/variables.json",
  );
  const packageRoot = path.resolve(path.dirname(variablesPath), "../..");
  const { version } = JSON.parse(
    await fs.readFile(path.join(packageRoot, "package.json"), "utf8"),
  ) as { version: string };
  const tokens = JSON.parse(
    await fs.readFile(variablesPath, "utf8"),
  ) as TokenFile;

  const blocks = new Map<TokenMode, Block>();
  const skippedComposites: string[] = [];
  for (const [token, node] of Object.entries(tokens)) {
    if (emitToken(blocks, tokens, token, node)) skippedComposites.push(token);
  }

  // Shims last so a name the token source later reclaims is won by the generated value
  // and the stale entry becomes visibly redundant rather than silently overriding.
  const generated = new Map(
    [...blocks].map(([mode, block]) => [mode, new Set(block.keys())] as const),
  );
  mergeShim(blocks, AUTHORED_SUPPLEMENTS);
  mergeShim(blocks, LEGACY_COMPONENT_TOKENS);

  const order: TokenMode[] = ["global", "light", "dark", "medium", "large"];
  const out: string[] = [
    "/* GENERATED - do not edit.",
    " * Source: @adobe/spectrum-tokens@" +
      version +
      " (dist/json/variables.json)",
    " * Producer: PAGI-WebServer/scripts/build-spectrum-tokens.ts",
    " * Regenerate with `pnpm build:css`.",
    " */",
    "",
  ];

  let count = 0;
  for (const mode of order) {
    const block = blocks.get(mode);
    if (!block || block.size === 0) continue;
    count += block.size;

    out.push(`${MODE_SELECTORS[mode]} {`);
    for (const prop of [...block.keys()].sort()) {
      out.push(`\t${prop}: ${block.get(prop)!};`);
    }
    out.push("}", "");
  }

  const outputPath = path.resolve(siteRoot, options.outFile);
  await fs.mkdir(path.dirname(outputPath), { recursive: true });
  await fs.writeFile(outputPath, out.join("\n"), "utf8");

  const shimmed =
    Object.values(AUTHORED_SUPPLEMENTS).reduce(
      (n, d) => n + Object.keys(d).length,
      0,
    ) +
    Object.values(LEGACY_COMPONENT_TOKENS).reduce(
      (n, d) => n + Object.keys(d).length,
      0,
    );
  const generatedCount = [...generated.values()].reduce(
    (n, s) => n + s.size,
    0,
  );

  console.log(
    `✔ Built ${path.relative(process.cwd(), outputPath)} ` +
      `(${count} declarations: ${generatedCount} from @adobe/spectrum-tokens@${version}, ` +
      `${shimmed} shimmed)`,
  );

  // Reported rather than swallowed: if something starts wanting a shadow or a typography
  // set, this line is where to look, and the fix is to teach the generator how to
  // decompose that shape rather than to hand-write the properties somewhere.
  if (skippedComposites.length > 0) {
    console.log(
      `  ${skippedComposites.length} composite token(s) skipped ` +
        `(no single-custom-property form): ${skippedComposites.join(", ")}`,
    );
  }
}
