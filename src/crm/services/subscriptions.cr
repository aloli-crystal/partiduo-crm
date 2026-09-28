# SPDX-License-Identifier: AGPL-3.0-or-later

module Crm
  # Abonnés des événements du cœur (ADR-003 D7, ADR-009), appelés dans la
  # transaction de l'opération, l'extension active. Ils relisent ce dont ils
  # ont besoin par `Partiduo::Api` avec l'acteur système. Interne.
  module Subscriptions
    alias Event = Partiduo::Events::Event
    alias Cards = Partiduo::Api::Cards
    alias Inv = Partiduo::Api::Invoicing

    def self.system : Partiduo::Api::Actor
      Partiduo::Api::Actor.system
    end

    # `card.saved` (ADR-009 D2) : une fiche *client* enregistrée hors du CRM
    # y apparaît sans double saisie — l'organisation rattachée est créée ou
    # mise à jour depuis la fiche (le cœur fait foi pour un client). Pendant
    # « Devenir client », la fiche est rattachée à l'organisation convertie.
    def self.card_saved(event : Event) : Nil
      card_id = event["card_id"].to_i64
      card = begin
        Cards.card(system, card_id)
      rescue Partiduo::Api::NotFound
        return
      end
      return unless card.kind == "customer"

      row = Organization.filter(card_id: card_id).first
      if row.nil? && (converting = Conversion.converting)
        row = Organization.filter(id: converting).first
      end
      row ||= Organization.new(owner_id: event.actor_user_id, created_by_id: event.actor_user_id)
      address = card.address
      row.card_id = card_id
      row.name = card.name[0, 200]
      row.nature = Api::NATURES.includes?(card.effective_nature) ? card.effective_nature : "business"
      row.siren = card.siren if card.siren.matches?(/\A\d{9}\z/)
      row.vat_number = card.vat_number[0, 32] unless card.vat_number.empty?
      row.email = card.email[0, 254] unless card.email.empty?
      row.phone = card.phone[0, 32] unless card.phone.empty?
      if address
        row.line1 = address.line1[0, 200]
        row.postcode = address.postcode[0, 16]
        row.city = address.city[0, 100]
        row.country_code = address.country_code[0, 2]
      end
      row.save!
    end

    # `quote.decided` (ADR-009 D5) : devis accepté → l'opportunité passe à
    # « Gagnée » ; refusé → elle reste ouverte et une activité « relancer »
    # est créée pour son responsable (une nouvelle version suit souvent).
    def self.quote_decided(event : Event) : Nil
      link = DocumentLink.filter(document_id: event["quote_id"].to_i64, kind: "quote").first
      return if link.nil?
      row = Records.opportunity!(link.opportunity_id!.to_i64, lock: true)
      stage = Records.stage!(row.stage_id!.to_i64)
      case event["decision"]
      when "accepted"
        Pipeline.move!(row, Records.closing_stage("won"), event.actor_user_id, "quote_accepted") unless stage.kind == "won"
      when "refused"
        return unless stage.kind == "open"
        number = event["number"]?.presence || event["quote_id"]
        Activity.create!(kind: "task", subject: I18n.t("crm.activities.follow_up", number: number)[0, 200],
          due_on: Records.today + FOLLOW_UP_DAYS.days, owner_id: row.owner_id, organization_id: row.organization_id,
          contact_id: row.contact_id, opportunity_id: row.id, done: false, created_by_id: event.actor_user_id)
      end
    end

    # `invoice.issued` (ADR-009 D5) : la facture tirée d'un devis lié à une
    # opportunité (directement ou par une commande) lui est rattachée.
    def self.invoice_issued(event : Event) : Nil
      invoice_id = event["invoice_id"].to_i64
      return if DocumentLink.filter(document_id: invoice_id).exists?
      document = Inv.document(system, invoice_id)
      source = document.source
      seen = 0
      while source && seen < 10
        if link = DocumentLink.filter(document_id: source.id, kind: "quote").first
          DocumentLink.create!(opportunity_id: link.opportunity_id, document_id: invoice_id, kind: "invoice",
            created_by_id: event.actor_user_id, created_at: Time.utc)
          return
        end
        source = Inv.document(system, source.id).source
        seen += 1
      end
    end

    FOLLOW_UP_DAYS = Api::FOLLOW_UP_DAYS
  end
end
