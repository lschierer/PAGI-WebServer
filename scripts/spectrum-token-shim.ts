// Custom properties that the retained @spectrum-css/* component packages read but
// @adobe/spectrum-tokens does not define.
//
// WHY THIS FILE EXISTS. The token layer is generated from @adobe/spectrum-tokens (see
// build-spectrum-tokens.ts). The component CSS still comes from @spectrum-css/*, whose
// last published token layer, @spectrum-css/tokens@16.0.2, was generated from
// @adobe/spectrum-tokens@0.0.0-s2-foundations-20241121221506 - a November 2024
// prerelease. In the ~22 months since, the token package dropped most per-component
// tokens (it carries exactly one button-* token now; the old layer carried forty) and
// renamed others. So swapping the generated layer in for @spectrum-css/tokens leaves a
// small set of properties that the component packages read and nothing declares.
//
// Every entry below was read out of @spectrum-css/tokens@16.0.2 and is grouped by the
// mode block it appeared in there, so the shim reproduces that layer's behavior exactly
// for these names and nothing else. The set was derived mechanically: for each of the
// eleven component packages a site imports, collect every var(--spectrum-*) it reads,
// subtract what the package declares itself, subtract what the generated layer supplies,
// and what is left is this list.
//
// THIS FILE SHOULD SHRINK. Each name here is owed to one @spectrum-css package. As a
// site replaces a component's markup and CSS, its entries become dead and should be
// deleted. An empty shim means the migration off @spectrum-css is finished.
//
// The two groups are not equivalent and should not be treated the same way:
//
//   LEGACY_COMPONENT_TOKENS - genuinely removed from the token source. These are frozen
//   values from a 2024 snapshot and are NOT design-system truth any more. Do not
//   introduce new uses; do not "update" them against current Spectrum.
//
//   AUTHORED_SUPPLEMENTS - never in the token source at all. @spectrum-css/tokens
//   hand-authored these on top of the generated output (font stacks especially, which
//   DTCG tokens describe as families, not as CSS fallback chains). These stay useful
//   after the component migration, so they are kept separate from the frozen group.
// cspell: disable

/** Mode blocks, in the selector form @spectrum-css/tokens uses. */
export type TokenMode = "global" | "light" | "dark" | "medium" | "large";

export const MODE_SELECTORS: Record<TokenMode, string> = {
  global: ".spectrum",
  light: ".spectrum--light",
  dark: ".spectrum--dark",
  medium: ".spectrum--medium",
  large: ".spectrum--large",
};

/**
 * Hand-authored additions @spectrum-css/tokens layered on top of its generated output.
 * Not present in @adobe/spectrum-tokens in any form, and still wanted after the
 * component packages are gone - the font stacks in particular, since the token source
 * names a family (--spectrum-sans-serif-font-family) and leaves the CSS fallback chain
 * to the consumer.
 */
export const AUTHORED_SUPPLEMENTS: Partial<
  Record<TokenMode, Record<string, string>>
> = {
  global: {
    "--spectrum-sans-font-family-stack":
      'adobe-clean, var(--spectrum-sans-serif-font-family), "Source Sans Pro", -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Ubuntu, "Trebuchet MS", "Lucida Grande", sans-serif',
    "--spectrum-serif-font-family-stack":
      'adobe-clean-serif, var(--spectrum-serif-font-family), "Source Serif Pro", Georgia, serif',
    "--spectrum-cjk-font-family-stack":
      "adobe-clean-han-japanese, var(--spectrum-cjk-font-family), sans-serif",
    "--spectrum-code-font-family-stack": '"Source Code Pro", Monaco, monospace',
    "--spectrum-font-family-ar":
      'myriad-arabic, adobe-clean, "Source Sans Pro", -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Ubuntu, "Trebuchet MS", "Lucida Grande", sans-serif',
    "--spectrum-font-family-he":
      'myriad-hebrew, adobe-clean, "Source Sans Pro", -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Ubuntu, "Trebuchet MS", "Lucida Grande", sans-serif',
    // The three unsuffixed defaults every typography sheet reaches for.
    "--spectrum-font-family": "var(--spectrum-sans-font-family-stack)",
    "--spectrum-font-size": "var(--spectrum-font-size-100)",
    "--spectrum-font-style": "var(--spectrum-default-font-style)",
  },
};

/**
 * Component tokens dropped from @adobe/spectrum-tokens after the November 2024
 * snapshot, still read by @spectrum-css/{button,treeview,alertbanner,icon}. Frozen at
 * the values @spectrum-css/tokens@16.0.2 shipped. Each will be deletable once the
 * component that reads it no longer comes from @spectrum-css.
 */
export const LEGACY_COMPONENT_TOKENS: Partial<
  Record<TokenMode, Record<string, string>>
> = {
  global: {
    // @spectrum-css/table's collapse animation; the token source has no duration ramp.
    "--spectrum-animation-duration-100": "130ms",
  },

  // @spectrum-css/treeview's selection wash. Mode-dependent because it is an alpha
  // over a scheme-specific grey/blue, which is why the -rgb forms matter.
  light: {
    "--spectrum-treeview-item-background-color-quiet-selected":
      "rgba(var(--spectrum-gray-900-rgb), 0.06)",
    "--spectrum-treeview-item-background-color-selected":
      "rgba(var(--spectrum-blue-900-rgb), 0.1)",
    // @spectrum-css/card's selection wash. This one only ever existed in the -rgb form:
    // there is no card-selected-background-color in the token source for the generator
    // to derive a companion from, so it has to be stated outright.
    "--spectrum-card-selected-background-color-rgb":
      "var(--spectrum-blue-900-rgb)",
  },
  dark: {
    "--spectrum-treeview-item-background-color-quiet-selected":
      "rgba(var(--spectrum-gray-900-rgb), 0.07)",
    "--spectrum-treeview-item-background-color-selected":
      "rgba(var(--spectrum-blue-800-rgb), 0.15)",
    "--spectrum-card-selected-background-color-rgb":
      "var(--spectrum-blue-500-rgb)",
  },

  // Scale-dependent. .spectrum--medium is the desktop scale, .spectrum--large the
  // mobile/touch one; the sites all set --medium today.
  medium: {
    "--spectrum-alert-banner-close-button-spacing":
      "var(--spectrum-spacing-100)",
    "--spectrum-alert-banner-edge-to-button": "var(--spectrum-spacing-100)",
    "--spectrum-alert-banner-edge-to-divider": "var(--spectrum-spacing-100)",
    "--spectrum-alert-banner-text-to-button-vertical":
      "var(--spectrum-spacing-100)",
    "--spectrum-button-top-to-text-small": "5px",
    "--spectrum-button-top-to-text-medium": "7px",
    "--spectrum-button-top-to-text-large": "10px",
    "--spectrum-button-top-to-text-extra-large": "13px",
    "--spectrum-button-bottom-to-text-small": "4px",
    "--spectrum-button-bottom-to-text-medium": "8px",
    "--spectrum-button-bottom-to-text-large": "10px",
    "--spectrum-button-bottom-to-text-extra-large": "13px",
    "--spectrum-treeview-item-indentation-small": "var(--spectrum-spacing-200)",
    "--spectrum-treeview-item-indentation-medium":
      "var(--spectrum-spacing-300)",
    // Not a spacing token in the source layer either - 20px sat between 300 and 400.
    "--spectrum-treeview-item-indentation-large": "20px",
    "--spectrum-treeview-item-indentation-extra-large":
      "var(--spectrum-spacing-400)",
    "--spectrum-treeview-item-min-block-size-thumbnail-offset-medium": "0px",
    // @spectrum-css/icon swaps icon sets by toggling display per scale.
    "--spectrum-ui-icon-medium-display": "block",
    "--spectrum-ui-icon-large-display": "none",
    "--spectrum-workflow-icon-size-xxs": "12px",
    "--spectrum-workflow-icon-size-xxl": "32px",
  },
  large: {
    "--spectrum-alert-banner-close-button-spacing":
      "var(--spectrum-spacing-200)",
    "--spectrum-alert-banner-edge-to-button": "var(--spectrum-spacing-200)",
    "--spectrum-alert-banner-edge-to-divider": "var(--spectrum-spacing-200)",
    "--spectrum-alert-banner-text-to-button-vertical":
      "var(--spectrum-spacing-200)",
    "--spectrum-button-top-to-text-small": "6px",
    "--spectrum-button-top-to-text-medium": "9px",
    "--spectrum-button-top-to-text-large": "12px",
    "--spectrum-button-top-to-text-extra-large": "16px",
    "--spectrum-button-bottom-to-text-small": "5px",
    "--spectrum-button-bottom-to-text-medium": "10px",
    "--spectrum-button-bottom-to-text-large": "13px",
    "--spectrum-button-bottom-to-text-extra-large": "17px",
    "--spectrum-treeview-item-indentation-small": "15px",
    "--spectrum-treeview-item-indentation-medium": "20px",
    "--spectrum-treeview-item-indentation-large": "25px",
    "--spectrum-treeview-item-indentation-extra-large": "30px",
    "--spectrum-treeview-item-min-block-size-thumbnail-offset-medium": "2px",
    "--spectrum-ui-icon-medium-display": "none",
    "--spectrum-ui-icon-large-display": "block",
    "--spectrum-workflow-icon-size-xxs": "15px",
    "--spectrum-workflow-icon-size-xxl": "40px",
  },
};
