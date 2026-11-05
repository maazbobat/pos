# Online ordering site

Each restaurant's own ordering site for pickup orders (Flutter web). A store
lives at `/#/<web address>`, for example `/#/maple-cambridge`; the manager
app sets the address under Online ordering.

Guests don't sign in. The site reads the menu and places orders through the
public `getStorefront`, `placeOnlineOrder` and `getOnlineOrderStatus`
Functions, which price everything on the server. See docs/orders.md.

```sh
flutter run -d chrome --web-port 8083
```
