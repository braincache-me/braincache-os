#!/usr/bin/env python3
"""Create a synthetic finance/accounting demo workspace for Activity Recording.

The generated files are intentionally fictional and safe to show on screen.
Run this script before recording to reset the demo workspace to a clean state.
"""

from __future__ import annotations

import csv
import shutil
from pathlib import Path
from textwrap import dedent


BASE_DIR = Path(__file__).resolve().parent
WORKSPACE_DIR = BASE_DIR / "demo_workspace"


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(dedent(content).strip() + "\n", encoding="utf-8")


def write_csv(path: Path, rows: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def reset_workspace() -> None:
    if WORKSPACE_DIR.exists():
        shutil.rmtree(WORKSPACE_DIR)
    (WORKSPACE_DIR / "vendor_invoices").mkdir(parents=True)
    (WORKSPACE_DIR / "working_notes").mkdir(parents=True)
    (WORKSPACE_DIR / "exports").mkdir(parents=True)


def build_files() -> None:
    reset_workspace()

    write_text(
        WORKSPACE_DIR / "00_START_HERE.md",
        """
        # Activity Recording Finance Demo

        Fictional company: Northstar Studio Supply
        Month-end close: May 2026
        Goal: review cash activity, match invoices, write close notes, and leave AI-searchable evidence.

        Safe demo data only. No real bank accounts, customers, vendors, or tax IDs are included.

        Demo objective:
        1. Identify the CloudWorks invoice and accrual treatment.
        2. Confirm the Harbor Retail customer payment.
        3. Flag the duplicate DeskHub subscription charge.
        4. Note that one EU contractor invoice needs VAT follow-up.
        5. Ask BrainCache later what happened during the close review.
        """,
    )

    write_csv(
        WORKSPACE_DIR / "bank_feed_may_2026.csv",
        [
            {
                "date": "2026-05-03",
                "description": "Stripe payout - online orders",
                "amount": "12840.25",
                "category": "Cash receipts",
                "memo": "Batch ST-0526-A",
            },
            {
                "date": "2026-05-07",
                "description": "CloudWorks Hosting INV-CW-1142",
                "amount": "-1284.00",
                "category": "Software and cloud services",
                "memo": "Needs accrual split: May usage, June billed",
            },
            {
                "date": "2026-05-09",
                "description": "OfficeMart invoice OFF-3821",
                "amount": "-346.18",
                "category": "Office supplies",
                "memo": "Receipt attached",
            },
            {
                "date": "2026-05-12",
                "description": "DeskHub subscription CHG-7741",
                "amount": "-219.00",
                "category": "Subscriptions",
                "memo": "Possible duplicate renewal",
            },
            {
                "date": "2026-05-13",
                "description": "DeskHub subscription CHG-7765",
                "amount": "-219.00",
                "category": "Subscriptions",
                "memo": "Review against CHG-7741",
            },
            {
                "date": "2026-05-18",
                "description": "Harbor Retail payment AR-2026-041",
                "amount": "7850.00",
                "category": "Customer payment",
                "memo": "Apply against April wholesale order",
            },
            {
                "date": "2026-05-22",
                "description": "EU freelance design INV-778",
                "amount": "-915.50",
                "category": "Contract labor",
                "memo": "VAT ID missing, follow up before close",
            },
            {
                "date": "2026-05-28",
                "description": "Bank service fee",
                "amount": "-18.00",
                "category": "Bank fees",
                "memo": "Auto-coded",
            },
        ],
    )

    write_csv(
        WORKSPACE_DIR / "ap_invoices_may_2026.csv",
        [
            {
                "invoice_id": "INV-CW-1142",
                "vendor": "CloudWorks Hosting",
                "invoice_date": "2026-05-01",
                "due_date": "2026-06-01",
                "amount": "1284.00",
                "gl_account": "6150 Software and Cloud Services",
                "status": "Approved",
                "owner": "Mia Chen",
            },
            {
                "invoice_id": "OFF-3821",
                "vendor": "OfficeMart",
                "invoice_date": "2026-05-08",
                "due_date": "2026-05-23",
                "amount": "346.18",
                "gl_account": "6450 Office Supplies",
                "status": "Matched",
                "owner": "Noah Patel",
            },
            {
                "invoice_id": "INV-778",
                "vendor": "Lumen Studio Design",
                "invoice_date": "2026-05-21",
                "due_date": "2026-06-05",
                "amount": "915.50",
                "gl_account": "6320 Contract Labor",
                "status": "Hold",
                "owner": "Elena Ortiz",
            },
        ],
    )

    write_csv(
        WORKSPACE_DIR / "ar_aging_may_2026.csv",
        [
            {
                "customer": "Harbor Retail",
                "invoice_id": "AR-2026-041",
                "invoice_date": "2026-04-24",
                "amount": "7850.00",
                "days_outstanding": "24",
                "status": "Paid 2026-05-18",
            },
            {
                "customer": "Brightline Events",
                "invoice_id": "AR-2026-052",
                "invoice_date": "2026-05-11",
                "amount": "3920.00",
                "days_outstanding": "18",
                "status": "Open",
            },
            {
                "customer": "Cedar & Co.",
                "invoice_id": "AR-2026-057",
                "invoice_date": "2026-05-20",
                "amount": "2245.75",
                "days_outstanding": "9",
                "status": "Open",
            },
        ],
    )

    write_text(
        WORKSPACE_DIR / "vendor_invoices" / "CloudWorks_INV-CW-1142.txt",
        """
        CLOUDWORKS HOSTING
        Invoice: INV-CW-1142
        Invoice date: 2026-05-01
        Due date: 2026-06-01

        Bill to: Northstar Studio Supply

        Description                         Amount
        Managed cloud hosting - May usage   $1,080.00
        Backup storage overage              $  204.00
        Total                               $1,284.00

        Accounting note:
        This invoice was approved by Mia Chen.
        Book to GL 6150 Software and Cloud Services.
        Accrue May usage because the cash payment posted before the close package was finalized.
        """,
    )

    write_text(
        WORKSPACE_DIR / "vendor_invoices" / "OfficeMart_OFF-3821.txt",
        """
        OFFICEMART
        Invoice: OFF-3821
        Invoice date: 2026-05-08

        Supplies for design team: $346.18
        Receipt matched to card transaction on 2026-05-09.
        No follow-up required.
        """,
    )

    write_text(
        WORKSPACE_DIR / "vendor_invoices" / "LumenStudio_INV-778.txt",
        """
        LUMEN STUDIO DESIGN
        Invoice: INV-778
        Invoice date: 2026-05-21
        Amount: $915.50

        Contract design support for Spring catalog.
        Payment hold: VAT ID is missing from the invoice.
        Follow up with Elena Ortiz before approving payment.
        """,
    )

    write_text(
        WORKSPACE_DIR / "customer_payment_email.txt",
        """
        From: ar@northstar-demo.example
        To: finance@northstar-demo.example
        Subject: Harbor Retail payment received

        Harbor Retail paid invoice AR-2026-041 on 2026-05-18.
        Amount received: $7,850.00.
        Apply the receipt against the April wholesale order and mark the AR item as paid.
        """,
    )

    write_text(
        WORKSPACE_DIR / "working_notes" / "month_end_reconciliation.md",
        """
        # May 2026 Month-End Reconciliation Notes

        Reviewer: Demo user
        Company: Northstar Studio Supply

        ## Cash receipts

        - Harbor Retail payment AR-2026-041 for $7,850.00 was received on 2026-05-18.

        ## Vendor payments

        - CloudWorks INV-CW-1142 for $1,284.00 needs to be accrued to GL 6150 Software and Cloud Services.

        ## Follow-ups

        - DeskHub has two subscription charges for $219.00 on consecutive days. Check whether CHG-7741 and CHG-7765 are duplicates.
        - Lumen Studio Design invoice INV-778 is on hold until the missing VAT ID is provided.

        ## Close conclusion

        Cash activity is mostly clean. The two open accounting issues are the DeskHub duplicate review and the Lumen VAT follow-up.
        """,
    )

    write_text(
        WORKSPACE_DIR / "working_notes" / "ai_questions_to_try.md",
        """
        # Questions to ask the AI after recording

        Try these after the activity has been recorded and indexed:

        1. What finance work did I just do?
        2. Which May close items still need follow-up?
        3. What happened with CloudWorks invoice INV-CW-1142?
        4. Which customer payment did I confirm?
        5. Was there any possible duplicate charge in the bank feed?
        """,
    )

    write_text(
        WORKSPACE_DIR / "exports" / "close_summary_to_copy.md",
        """
        May close summary:
        CloudWorks INV-CW-1142 should be accrued to GL 6150 for $1,284.00.
        Harbor Retail AR-2026-041 was paid in full for $7,850.00.
        Follow up on duplicate DeskHub subscription charges and missing VAT details for Lumen Studio INV-778.
        """,
    )


def main() -> None:
    build_files()
    print(f"Created finance demo workspace: {WORKSPACE_DIR}")
    print("Open 00_START_HERE.md first, then follow demo_recording_script.md.")


if __name__ == "__main__":
    main()
