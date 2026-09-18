// postcss-extend ships no type declarations, so scripts/build-css.ts cannot import it
// under `strict`.
//
// This lives in the framework package because the CSS build does. It was previously
// duplicated in all three sites that extended the framework; with one build script
// there is one declaration.
declare module "postcss-extend" {
  import { type PluginCreator } from "postcss";
  const extend: PluginCreator<object>;
  export default extend;
}
