/// <reference path="../types/postcss-extend.d.ts" />
// The reference above is load-bearing: postcss-extend ships no types, and any project
// that compiles THIS file needs that declaration in its program. A site's tsconfig
// includes only its own directories, so without the reference each site would have to
// add the framework's types/ to its include list. This keeps the declaration travelling
// with the code that needs it.
// The shared CSS build for this framework and every site that extends it.
//
// WHY THIS LIVES IN THE PARENT. Three sites carried byte-identical copies of this
// file (App-Schierer-HPFan, Game-EvonyTKR, originalFiction), differing only in which
// directory their stylesheets sit in. Duplication of a build step is duplication of
// its bugs: Game-EvonyTKR's copy had drifted so that postcss-import was told to look
// in "./styles" while its stylesheets are in "share/styles", so a bare @import of a
// sibling sheet resolved in two of the three sites and not the third. One copy, with
// the varying part passed in, removes that class of divergence.
//
// WHY NOT A PNPM WORKSPACE. A workspace spanning the parent and its children would
// require every member checked out to resolve the links, which defeats the point:
// working on one site should need that site and this framework, nothing else. So the
// coupling is a sibling-relative path, exactly as the Perl side already does it with
// `use lib '../PAGI-WebServer/lib'` and the Template include paths.
//
// WHY NOT postcss-cli. It could not reliably load a TypeScript config despite the
// documentation saying it was supported - config loading is postcss-load-config's
// job and it kept failing. The plugin list and its ORDER live here instead, in code,
// where they are explicit and type-checked. postcss-cli is not a dependency of any of
// these projects.
//
// HOW A SITE USES IT. Its scripts/build-css.ts is a shim:
//
//     import { buildCSS } from "../../PAGI-WebServer/scripts/build-css.ts";
//     await buildCSS({ stylesDir: "styles" });
//
// The output directory comes from argv so the existing package.json scripts keep
// working unchanged. stylelint.config.js is resolved from the SITE's working
// directory, so each site keeps its own rules.

import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import postcss, { type CssSyntaxError } from "postcss";

import postcssImport from "postcss-import";
import postcssExtend from "postcss-extend";
import postcssNesting from "postcss-nesting";
import postcssSorting from "postcss-sorting";
import autoprefixer from "autoprefixer";
import cssnano from "cssnano";
import stylelint from "stylelint";

import { buildSpectrumTokens } from "./build-spectrum-tokens.ts";

export interface BuildCSSOptions {
  /** Where the site keeps its stylesheets, relative to the site root. */
  stylesDir: string;
  /** Output directory. Defaults to argv[2], which is how the sites invoke it. */
  outDir?: string;
  /** Append cssnano. Defaults to --minify in argv. */
  minify?: boolean;
  /**
   * Where to write the generated Spectrum token layer, relative to the site root.
   * Defaults to `<stylesDir>/generated/spectrum-tokens.css`.
   *
   * A SUBDIRECTORY ON PURPOSE. Both the loop below and the stylelint glob read
   * `<stylesDir>/*.css` without recursing, so a sheet in `generated/` is never linted
   * (it is machine output, not something a site's rules should judge) and never emitted
   * as a standalone file. It reaches the browser only where a hand-written sheet
   * @imports it, which is the behaviour wanted: one token layer, inlined into each sheet
   * that needs it, exactly as @spectrum-css/tokens was.
   */
  tokensFile?: string;
}

export async function buildCSS(options: BuildCSSOptions): Promise<void> {
  const argv = process.argv.slice(2);

  if (options.outDir === undefined && argv.length < 1) {
    console.error("Usage: tsx build-css.ts <output-dir> [--minify]");
    process.exit(1);
  }

  const outDir = options.outDir ?? argv[0];
  const minify = options.minify ?? argv.includes("--minify");

  const stylesDir = path.resolve(options.stylesDir);
  const outputDir = path.resolve(outDir);

  // Before linting, because a sheet that @imports the token layer needs it to exist, and
  // before postcss-import inlines anything, for the same reason.
  await buildSpectrumTokens({
    outFile:
      options.tokensFile ??
      path.join(options.stylesDir, "generated/spectrum-tokens.css"),
  });

  // Lint first, fixing what can be fixed. A remaining error aborts the build -
  // a stylesheet that does not satisfy the site's own rules should not ship.
  try {
    const result = await stylelint.lint({
      configFile: "stylelint.config.js",
      files: `${options.stylesDir}/*.css`,
      fix: true,
    });
    if (result.errored && result.report) {
      console.error("css error:", result.report);
      process.exit(1);
    }
  } catch (err) {
    console.error((err as Error).stack ?? String(err));
  }

  // ORDER IS LOAD-BEARING: inline the imports before anything inspects the tree,
  // resolve @extend, flatten nesting, then sort, then prefix. cssnano last, and
  // only when minifying, so the unminified output stays readable in dev.
  const plugins = [
    postcssImport({
      // stylesDir is included so a sheet can @import a sibling by bare name,
      // whatever directory the site keeps them in.
      path: ["node_modules", ".", options.stylesDir],
    }),
    postcssExtend(),
    postcssNesting(),
    postcssSorting({
      order: ["custom-properties", "declarations", "at-rules", "rules"],
      "properties-order": "alphabetical",
    }),
    autoprefixer(),
  ];

  if (minify) {
    plugins.push(cssnano({ preset: "default" }));
  }

  await fs.mkdir(outputDir, { recursive: true });

  const entries = await fs.readdir(stylesDir);
  const cssFiles = entries.filter((file) => file.endsWith(".css"));

  for (const file of cssFiles) {
    const inputPath = path.join(stylesDir, file);
    const outputPath = path.join(outputDir, file);
    const css = await fs.readFile(inputPath, "utf8");

    // A failing sheet warns and the build moves on, rather than aborting. That is
    // the behaviour the three site copies had and it is preserved deliberately:
    // one broken stylesheet should not deny the site every other stylesheet.
    try {
      const result = await postcss(plugins).process(css, {
        from: inputPath,
        to: outputPath,
      });

      await fs.writeFile(outputPath, result.css, "utf8");
      console.log(`✔ Built ${path.relative(process.cwd(), outputPath)}`);
    } catch (err) {
      if (typeof err === "object" && err) {
        if (err instanceof Error) {
          console.warn(`⚠️  Failed to build ${file}: ${err.message}`);
        }
        if ("name" in err && err.name === "CssSyntaxError") {
          console.warn((err as CssSyntaxError).showSourceCode());
        }
      }
    }
  }
}
