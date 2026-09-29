# SPDX-License-Identifier: AGPL-3.0-or-later

module Crm
  module Ui
    # Ligne présentée à un gabarit : textes déjà mis en forme, par nom (un
    # grand `Hash` n'est pas lu par les gabarits Marten, B-EINV-001 du cœur).
    class Row
      include Marten::Template::Object

      getter values : Hash(String, String?)
      getter children : Hash(String, Array(Row))

      def initialize(values : Hash(String, String) | Hash(String, String?), @children = {} of String => Array(Row))
        @values = values.transform_values(&.as(String?))
      end

      def resolve_template_attribute(key : String)
        if list = children[key]?
          list.empty? ? nil : list
        else
          values[key]?
        end
      end
    end

    def self.row(values : Hash(String, String) | Hash(String, String?), children = {} of String => Array(Row)) : Row
      Row.new(values, children)
    end

    def self.url(name : String, **params) : String
      Marten.routes.reverse("crm:#{name}", **params)
    end

    # Adresse d'un écran de l'interface commune (fiche, document).
    def self.route(name : String, **params) : String
      Marten.routes.reverse(name, **params)
    end

    def self.flag(value : Bool) : String?
      value ? "1" : nil
    end

    # Icône de la planche de l'interface pour chaque nature d'activité.
    KIND_ICONS = {"call" => "phone", "meeting" => "calendar", "email" => "mail", "task" => "check", "note" => "notebook-pen"}

    # Lien `tel:` d'un numéro (espaces, points, tirets et parenthèses
    # retirés) ; `nil` si le numéro est vide.
    def self.tel(number : String?) : String?
      digits = number.to_s.gsub(/[\s.\-()]/, "")
      digits.empty? ? nil : "tel:#{digits}"
    end

    # Lien `mailto:` d'une adresse ; `nil` si elle est vide.
    def self.mailto(email : String?) : String?
      email.presence.try { |address| "mailto:#{address}" }
    end

    # Classe Bulma d'une étape ou d'un statut d'opportunité.
    def self.status_class(status : String) : String
      case status
      when "won"  then "is-success"
      when "lost" then "is-danger"
      else             "is-info"
      end
    end

    # Présentation des vues du contrat (interne à l'interface).
    module Present
      alias Api = Crm::Api

      def self.opportunity(view : Api::OpportunityView, fmt : PartiduoUi::Format, owners : Hash(Int64, String)) : Row
        Ui.row({
          "id"           => view.id.to_s,
          "url"          => Ui.url("opportunity", id: view.id),
          "title"        => view.title,
          "organization" => view.organization_name,
          "customer"     => Ui.flag(view.organization_customer),
          "contact"      => view.contact_name,
          "amount"       => fmt.amount(view.amount),
          "weighted"     => fmt.amount(view.weighted_amount),
          "probability"  => "#{view.probability} %",
          "close_on"     => view.expected_close_on.try { |date| fmt.date(date) },
          "owner"        => view.owner_id.try { |id| owners[id]? },
          "stage"        => view.stage.label,
          "stage_id"     => view.stage.id.to_s,
          "status"       => view.status,
          "status_label" => I18n.t(view.status_key),
          "status_class" => Ui.status_class(view.status),
          "no_next_step" => Ui.flag(view.no_next_step?),
          "next_on"      => view.next_activity_on.try { |date| fmt.date(date) },
        })
      end

      def self.activity(view : Api::ActivityView, fmt : PartiduoUi::Format, owners : Hash(Int64, String),
                        today : Time) : Row
        target = view.opportunity_title || view.contact_name || view.organization_name
        target_url = if opportunity = view.opportunity_id
                       Ui.url("opportunity", id: opportunity)
                     elsif contact = view.contact_id
                       Ui.url("contact", id: contact)
                     elsif organization = view.organization_id
                       Ui.url("organization", id: organization)
                     end
        Ui.row({
          "id"          => view.id.to_s,
          "kind"        => I18n.t(view.kind_key),
          "kind_code"   => view.kind,
          "kind_icon"   => KIND_ICONS[view.kind]? || "calendar",
          "subject"     => view.subject,
          "due_on"      => fmt.date(view.due_on),
          "starts_at"   => view.starts_at.try(&.to_s("%H:%M")),
          "duration"    => view.duration_minutes.try { |minutes| I18n.t("crm_ui.activities.minutes", count: minutes) },
          "owner"       => view.owner_id.try { |id| owners[id]? },
          "report"      => view.report.presence,
          "done"        => Ui.flag(view.done),
          "late"        => Ui.flag(view.late?(today)),
          "target"      => target,
          "target_url"  => target_url,
          "edit_url"    => Ui.url("activity_edit", id: view.id),
          "done_url"    => Ui.url("activity_done", id: view.id),
          "delete_url"  => Ui.url("activity_delete", id: view.id),
          "contact"     => view.contact_name,
          "contact_url" => view.contact_id.try { |id| Ui.url("contact", id: id) },
        })
      end
    end
  end
end
