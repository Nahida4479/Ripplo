// A link shows as "BLE Coded" when it runs on the Coded PHY (native note "phy coded"), on the BLE GATT link or its L2CAP link.
export const isCodedLink = l => ['ble', 'l2cap'].includes(String(l?.medium).toLowerCase()) && /coded/.test(l?.note || '')
