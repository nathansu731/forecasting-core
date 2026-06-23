# Provider Guidance

## QuickBooks
QuickBooks connections depend on Intuit OAuth and access to the selected company. Users may need invoice, sales receipt, and item access for a useful import.

## Shopify
Shopify connections depend on store install permissions and the scopes required for orders, products, and inventory data.

## BigCommerce
BigCommerce connections depend on store authorization and the scopes needed for orders, catalog, and inventory endpoints.

## Amazon
Amazon Seller integrations are more permission sensitive. Marketplace access, token exchange, and reporting scope can all block imports.

## Assistant Guidance
When import setup fails, the assistant should point to missing permissions, inaccessible entities, or field compatibility before suggesting a retry.
