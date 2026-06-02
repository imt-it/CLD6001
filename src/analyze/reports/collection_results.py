#!/usr/bin/env python3
"""Collection-result normalization helpers."""

from __future__ import annotations


SUCCESS_RESULTS = {"success", "pass"}
FAILURE_RESULTS = {"failure", "fail"}
BLOCKED_RESULTS = {"block", "blocked"}
COLLECTION_RESULT_RUNTIME_KEYS = frozenset(
    {"docker-rootful", "docker-rootless", "podman-rootless"}
)


def get_collection_identifier(collection_result):
    """Return the normalized collection identifier from a raw result payload."""
    return collection_result.get(
        "collection",
        collection_result.get("phase", "unknown"),
    )


def normalize_outcome(value):
    """Normalize mixed result labels."""
    if not isinstance(value, str):
        return "unknown"

    normalized = value.lower()
    if normalized in SUCCESS_RESULTS:
        return "success"
    if normalized in FAILURE_RESULTS:
        return "failure"
    if normalized in BLOCKED_RESULTS:
        return "blocked"
    return normalized


def normalize_test_case_record(test_case_id, test_case_payload, runtime=None):
    """Normalize one test-case payload."""
    raw_status = (test_case_payload.get("status")
                  if isinstance(test_case_payload, dict) else None)
    raw_result = (test_case_payload.get("result", raw_status)
                  if isinstance(test_case_payload, dict) else test_case_payload)
    normalized_status = normalize_outcome(raw_result)
    reason_code = (test_case_payload.get("reason_code")
                   if isinstance(test_case_payload, dict) else None)
    reason_text = (test_case_payload.get("reason_text")
                   if isinstance(test_case_payload, dict) else None)
    reason_source = (test_case_payload.get("reason_source")
                     if isinstance(test_case_payload, dict) else None)
    description = (test_case_payload.get("description")
                   if isinstance(test_case_payload, dict) else None)
    details = (test_case_payload.get("details")
               if isinstance(test_case_payload, dict) else None)

    if normalized_status in {"failure", "blocked"}:
        reason_code = reason_code or "unknown"
        reason_text = reason_text or "Unknown"
        reason_source = reason_source or "derived-default"

    record = {
        "runtime": runtime,
        "test_case_id": test_case_id,
        "status": normalized_status,
        "raw_status": raw_status,
        "raw_result": raw_result,
    }
    if reason_code:
        record["reason_code"] = reason_code
    if reason_text:
        record["reason_text"] = reason_text
    if reason_source:
        record["reason_source"] = reason_source
    if description:
        record["description"] = description
    if details:
        record["details"] = details
    return record


def iter_flattened_test_case_items(collection_result):
    """Yield flattened legacy test-case entries."""
    flattened_test_cases = collection_result.get("test_cases", [])
    if isinstance(flattened_test_cases, dict):
        return list(flattened_test_cases.items())

    return [
        (
            test_case.get("test_case_id", "unknown")
            if isinstance(test_case, dict) else "unknown",
            test_case,
        )
        for test_case in flattened_test_cases
    ]


def is_runtime_test_case_payload(payload):
    """Return True when a top-level payload matches the current runtime result shape."""
    return isinstance(payload, dict) and isinstance(payload.get("test_cases"), dict)


def is_runtime_preflight_checks_payload(payload):
    """Return True when a runtime payload matches the current preflight check shape."""
    return isinstance(payload, dict) and isinstance(payload.get("checks"), dict)


def is_preflight_collection_result(collection_result):
    """Return True when the collection payload represents preflight results."""
    collection_name = collection_result.get("collection", collection_result.get("phase"))
    return collection_name == "preflight"


def iter_runtime_result_items(collection_result, runtime_payload):
    """Yield normalized runtime result items across supported runtime payload shapes."""
    if is_runtime_test_case_payload(runtime_payload):
        return runtime_payload["test_cases"].items()
    if (
        is_preflight_collection_result(collection_result)
        and is_runtime_preflight_checks_payload(runtime_payload)
    ):
        return runtime_payload["checks"].items()
    return ()


def iter_runtime_payload_items(collection_result):
    """Yield supported top-level runtime payloads."""
    unsupported_runtime_keys = []

    for runtime_name, runtime_payload in collection_result.items():
        runtime_items = iter_runtime_result_items(collection_result, runtime_payload)
        if not runtime_items:
            continue
        if runtime_name in COLLECTION_RESULT_RUNTIME_KEYS:
            yield runtime_name, runtime_payload
            continue
        unsupported_runtime_keys.append(runtime_name)

    if unsupported_runtime_keys:
        supported = ", ".join(sorted(COLLECTION_RESULT_RUNTIME_KEYS))
        unsupported = ", ".join(sorted(unsupported_runtime_keys))
        raise ValueError(
            f"Unsupported collection-result runtime key(s): {unsupported}. "
            f"Expected one of: {supported}."
        )


def normalize_collection_result(collection_result):
    """Normalize a collection-result payload."""
    normalized_results = []
    collection_identifier = get_collection_identifier(collection_result)

    for runtime_name, runtime_payload in iter_runtime_payload_items(collection_result):
        for test_case_id, test_case_payload in iter_runtime_result_items(
            collection_result, runtime_payload
        ):
            normalized_results.append(
                normalize_test_case_record(
                    test_case_id, test_case_payload,
                    runtime=runtime_name
                )
            )

    if not normalized_results:
        normalized_results = [
            normalize_test_case_record(
                test_case.get("test_case_id", "unknown"), test_case
            )
            for test_case in collection_result.get("results", [])
            if isinstance(test_case, dict)
        ]

        existing_test_case_ids = {
            test_case["test_case_id"]
            for test_case in normalized_results
            if test_case.get("test_case_id") != "unknown"
        }
        for test_case_id, test_case_payload in iter_flattened_test_case_items(
            collection_result
        ):
            if test_case_id in existing_test_case_ids:
                continue
            normalized_results.append(
                normalize_test_case_record(test_case_id, test_case_payload)
            )
            if test_case_id != "unknown":
                existing_test_case_ids.add(test_case_id)

    if not normalized_results:
        normalized_results = [
            normalize_test_case_record(test_case_id, test_case_payload)
            for test_case_id, test_case_payload in
            iter_flattened_test_case_items(collection_result)
        ]

    if (
        not normalized_results
        and collection_result.get("kind") == "testcase"
        and collection_identifier != "preflight"
    ):
        raise ValueError(
            "Non-preflight testcase collection result for collection "
            f"{collection_identifier} contains no testcase data."
        )

    normalized_test_cases = [
        test_case["status"] for test_case in normalized_results
    ]

    return {
        "collection": collection_identifier,
        "title": collection_result.get("title", "unknown"),
        "test_cases": normalized_test_cases,
        "results": normalized_results,
    }


normalize_phase_result = normalize_collection_result
