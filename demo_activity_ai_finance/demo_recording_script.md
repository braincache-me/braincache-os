# Activity Recording Demo Script: Finance Close Review

## Setup Before Recording

1. Run `python3 create_finance_demo_files.py`.
2. Open the generated `demo_workspace` folder in Finder.
3. Start Activity Recording in BrainCache.
4. Keep the screen clean: close unrelated documents, browser tabs, and apps.

## Demo Story

You are doing a May 2026 month-end close review for the fictional company Northstar Studio Supply. The recording should show you opening files, reading accounting evidence, copying one short summary, and updating close notes. Afterward, BrainCache AI should be able to answer questions about what happened.

## Screen Recording Flow

### 1. Start With the Brief

Open `demo_workspace/00_START_HERE.md`.

Voiceover:

> I am going to review a small month-end close package. The goal is to confirm cash receipts, match a few vendor invoices, and leave searchable notes for later.

On screen:

- Point out that all data is fictional.
- Mention that the work involves bank activity, AP invoices, AR aging, and follow-up notes.

### 2. Review the Bank Feed

Open `demo_workspace/bank_feed_may_2026.csv`.

Voiceover:

> First I am checking the May bank feed. I see a CloudWorks hosting charge, a Harbor Retail payment, and two DeskHub subscription charges that look suspiciously similar.

On screen:

- Highlight or click the `CloudWorks Hosting INV-CW-1142` row.
- Highlight or click the `Harbor Retail payment AR-2026-041` row.
- Highlight or click both `DeskHub subscription` rows.

What Activity Recording should capture:

- The file name.
- The transaction descriptions.
- The fact that you inspected a possible duplicate charge.

### 3. Match the CloudWorks Invoice

Open `demo_workspace/vendor_invoices/CloudWorks_INV-CW-1142.txt`.

Voiceover:

> Now I am matching the CloudWorks invoice. The amount is $1,284.00, it was approved by Mia Chen, and it should be booked to GL 6150 Software and Cloud Services.

On screen:

- Select the line `Book to GL 6150 Software and Cloud Services.`
- Copy it with Cmd+C.
- Paste it into `demo_workspace/working_notes/month_end_reconciliation.md` under Vendor payments, or simply click into the existing note and make a small edit like adding `Approved by Mia Chen.`

What Activity Recording should capture:

- File open and text selection.
- Clipboard activity.
- Note editing.

### 4. Confirm the Customer Payment

Open `demo_workspace/customer_payment_email.txt`.

Voiceover:

> Next I am confirming that Harbor Retail paid invoice AR-2026-041 for $7,850.00. I will make sure the close notes say this customer payment was received and applied.

On screen:

- Read the payment line.
- Open `demo_workspace/working_notes/month_end_reconciliation.md`.
- Add or edit a sentence: `Harbor Retail AR-2026-041 is paid in full.`

### 5. Flag Remaining Accounting Issues

Open `demo_workspace/vendor_invoices/LumenStudio_INV-778.txt`, then return to `bank_feed_may_2026.csv`.

Voiceover:

> There are two follow-ups before close: Lumen Studio is missing a VAT ID, and DeskHub may have billed the subscription twice.

On screen:

- Show the Lumen VAT hold.
- Show the two DeskHub charges.
- Return to `month_end_reconciliation.md`.
- Add or point at the follow-up bullets.

### 6. Copy the Final Close Summary

Open `demo_workspace/exports/close_summary_to_copy.md`.

Voiceover:

> I am copying a clean close summary so the activity log has a concise final artifact that the AI can reuse.

On screen:

- Select the three-line close summary.
- Copy it with Cmd+C.
- Paste it into `month_end_reconciliation.md` under `Close conclusion`, or into a fresh temporary note window.

### 7. Ask AI Questions

After the recording has been processed, open BrainCache AI chat and ask:

1. What finance work did I just do?
2. Which May close items still need follow-up?
3. What happened with CloudWorks invoice INV-CW-1142?
4. Which customer payment did I confirm?
5. Was there any possible duplicate charge in the bank feed?

Expected AI answer themes:

- You reviewed May 2026 close files for Northstar Studio Supply.
- CloudWorks INV-CW-1142 was matched, approved by Mia Chen, and accrued to GL 6150 for $1,284.00.
- Harbor Retail paid AR-2026-041 for $7,850.00.
- DeskHub may have a duplicate $219.00 subscription charge.
- Lumen Studio INV-778 needs VAT ID follow-up before approval.

## Short Version for a 60-Second Recording

1. Open `bank_feed_may_2026.csv`.
2. Point at CloudWorks, Harbor Retail, and the two DeskHub rows.
3. Open `CloudWorks_INV-CW-1142.txt`.
4. Copy the GL 6150 accounting line.
5. Paste it into `month_end_reconciliation.md`.
6. Open `customer_payment_email.txt`.
7. Add `Harbor Retail AR-2026-041 is paid in full.`
8. Open BrainCache AI and ask: `What finance work did I just do, and what still needs follow-up?`

