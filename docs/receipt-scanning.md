# Local receipt scanning

In Add/Edit Transaction, choose **Scan Receipt**, then scan one paper receipt page with Apple's document camera or pick a receipt photo/screenshot. Apple Vision reads the image locally; no receipt image or OCR text is uploaded by the scanner.

Review and edit the merchant/title, total, currency, transaction type (expense or income/refund), and optional date. You may attach the downsampled receipt image, replacing the current attachment. **Use Receipt** only populates the transaction form; the normal save action and currency-conversion validation are still required. Category and notes remain unchanged. A changed currency or day clears the old manual exchange rate.

On iOS 26 with Apple Intelligence available, an on-device language model interprets the entire OCR document without requiring store templates, fixed field positions, or predefined total labels. Structured suggestions are checked against literal text on the receipt; invented values and ambiguous currency symbols are rejected. Conflicting interpretations require manual entry. This is layout-agnostic extraction, not a guarantee of perfect recognition of every image or language. Item prices are never summed, and the largest price is never assumed to be the total.

If the on-device model is unavailable, fails, or the OCR text exceeds its input limit, a clearly disclosed basic parser supplies conservative suggestions for English, Russian, and Bosnian final-total labels. Full recognized text remains available for manual review. OCR accuracy varies by lighting and layout. Dates with ambiguous order require confirmation; a bare dollar sign never establishes USD. No remote AI fallback is used.

First-version limits: one page at a time, image inputs up to 20 MB, no PDF import, line-item breakdown, fiscal QR lookup, or automatic transaction creation. Camera availability and recognition languages depend on the device's Apple APIs. Permission denial, unreadable images, and cancellation have explicit handling.

Regression tests cover parser ambiguities, grounded semantic suggestions, and draft application/rate invalidation. On October 4, 2026, the Debug build and all 75 tests passed on the dedicated iPhone 17 / iOS 27 simulator, including the receipt tests and a disposable migration fixture reconstructed from the owner's complete export. Camera/photo-picker interaction, real OCR layouts, and actual on-device model inference still need physical-device verification; passing deterministic parser tests does not prove those runtime flows.
