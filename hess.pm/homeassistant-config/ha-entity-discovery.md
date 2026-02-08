# Home Assistant Entity Discovery

How to query Home Assistant for entities, friendly names, and labels.

## Prerequisites

- HA instance: `https://homeassistant.hess.pm`
- A long-lived access token (create in HA under Profile > Security > Long-Lived Access Tokens)
- Store the token in an env var: `export HA_API_TOKEN="your-token-here"`

## REST API

All requests require the header: `Authorization: Bearer $HA_API_TOKEN`

### List all entities with state and attributes

```bash
curl -s -H "Authorization: Bearer $HA_API_TOKEN" \
  https://homeassistant.hess.pm/api/states | jq '.[0]'
```

Response shape per entity:

```json
{
  "entity_id": "light.buero_jonas",
  "state": "on",
  "attributes": {
    "friendly_name": "Buro Jonas",
    "brightness": 255,
    "color_temp": 370
  },
  "last_changed": "2025-01-15T10:30:00+00:00"
}
```

### Filter by domain

Entities follow the pattern `domain.object_id`. Common domains:

| Domain     | Example                    |
|------------|----------------------------|
| `light`    | `light.wohnzimmer`         |
| `switch`   | `switch.steckdose_kueche`  |
| `scene`    | `scene.abendessen`         |
| `script`   | `script.gute_nacht`        |
| `sensor`   | `sensor.temperatur_aussen` |
| `fan`      | `fan.ventilator`           |
| `group`    | `group.alle_lichter`       |
| `climate`  | `climate.heizung_bad`      |
| `cover`    | `cover.rolladen_wohnzimmer`|

Filter client-side:

```bash
curl -s -H "Authorization: Bearer $HA_API_TOKEN" \
  https://homeassistant.hess.pm/api/states \
  | jq '[.[] | select(.entity_id | startswith("light."))] | length'
```

### Get a single entity

```bash
curl -s -H "Authorization: Bearer $HA_API_TOKEN" \
  https://homeassistant.hess.pm/api/states/light.buero_jonas | jq .
```

### Extract entity_id + friendly_name pairs

```bash
curl -s -H "Authorization: Bearer $HA_API_TOKEN" \
  https://homeassistant.hess.pm/api/states \
  | jq '[.[] | {entity_id, friendly_name: .attributes.friendly_name}]'
```

### Search entities by friendly name

```bash
curl -s -H "Authorization: Bearer $HA_API_TOKEN" \
  https://homeassistant.hess.pm/api/states \
  | jq '[.[] | select(.attributes.friendly_name | test("küche"; "i"))]'
```

## WebSocket API

The WebSocket API at `wss://homeassistant.hess.pm/api/websocket` provides access to the entity registry, which includes label assignments (not available via REST).

### Entity registry (includes labels)

```json
{"type": "auth", "access_token": "YOUR_TOKEN"}
{"id": 1, "type": "config/entity_registry/list"}
```

Each entry includes:

```json
{
  "entity_id": "scene.abendessen",
  "labels": ["room_wohnzimmer", "time_abend"]
}
```

### Label registry

```json
{"id": 2, "type": "config/label_registry/list"}
```

## SmartHome4-UI API

The SmartHome4-UI backend wraps these HA calls with convenience endpoints:

| Endpoint                              | Description                                      |
|---------------------------------------|--------------------------------------------------|
| `GET /api/config/ha-entities`         | Entity IDs filtered to scene/script/light/group/fan |
| `GET /api/config/ha-entities-detailed`| All entities with friendly names (no filtering)  |
| `GET /api/labels/state`              | All HA labels with names, colors, icons          |

These are available at `https://lights.hess.pm/api/...` (behind oauth2-proxy).
