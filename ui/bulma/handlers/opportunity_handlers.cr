# SPDX-License-Identifier: AGPL-3.0-or-later

module Crm
  module Ui
    # Formulaire et lecture d'une opportunité (création, modification).
    abstract class OpportunityScreen < Handler
      def opportunity_crumbs(title : String? = nil, url : String? = nil) : Array(Screen::Crumb)
        list = crumbs({I18n.t("crm.menu.crm_opportunities"), title ? Ui.url("opportunities") : nil})
        list << Screen::Crumb.new(title, url) if title
        list
      end

      # Valeurs du formulaire : celles d'une opportunité, ou les défauts.
      def values_of(view : Api::OpportunityView?) : Hash(String, String)
        return {"organization_id" => query("organization"), "contact_id" => query("contact"),
                "owner_id" => actor.user_id.to_s, "amount" => "", "probability" => ""} unless view
        {
          "title"             => view.title,
          "organization_id"   => view.organization_id.to_s,
          "contact_id"        => view.contact_id.to_s,
          "amount"            => fmt.amount(view.amount, group: false),
          "probability"       => view.probability.to_s,
          "expected_close_on" => Ui.iso(view.expected_close_on),
          "owner_id"          => view.owner_id.to_s,
          "source_id"         => view.source_id.to_s,
        }
      end

      def submitted : Hash(String, String)
        %w[title organization_id contact_id amount probability expected_close_on owner_id stage_id source_id]
          .to_h { |name| {name, field(name)} }
      end

      def opportunity_form(values : Hash(String, String), creating : Bool) : Form
        main = [
          Form::Field.new("title", I18n.t("crm_ui.opportunities.title_field"), value: values["title"]? || "", required: true,
            maxlength: 200, wide: true),
          Form::Field.new("organization_id", I18n.t("crm_ui.opportunities.organization"), "select",
            values["organization_id"]? || "", options: organization_options, required: true),
          Form::Field.new("contact_id", I18n.t("crm_ui.opportunities.contact"), "select", values["contact_id"]? || "",
            options: contact_options, help: I18n.t("crm_ui.opportunities.contact_help")),
        ]
        figures = [
          Form::Field.new("amount", I18n.t("crm_ui.opportunities.amount"), "number", values["amount"]? || "", mono: true,
            help: I18n.t("crm_ui.opportunities.amount_help")),
          Form::Field.new("probability", I18n.t("crm_ui.opportunities.probability"), "number", values["probability"]? || "",
            mono: true, help: I18n.t("crm_ui.opportunities.probability_help")),
          Form::Field.new("expected_close_on", I18n.t("crm_ui.opportunities.close_on"), "date", values["expected_close_on"]? || ""),
          Form::Field.new("owner_id", I18n.t("crm_ui.opportunities.owner"), "select", values["owner_id"]? || "", options: owner_options),
          Form::Field.new("source_id", I18n.t("crm_ui.opportunities.source"), "select", values["source_id"]? || "",
            options: source_options),
        ]
        if creating
          stages = Api.stages(actor, active_only: true).select(&.open?).map { |stage| option(stage.id.to_s, stage.label) }
          figures.unshift(Form::Field.new("stage_id", I18n.t("crm_ui.opportunities.stage"), "select", values["stage_id"]? || "",
            options: stages))
        end
        Form.new([Form::Group.new(nil, main), Form::Group.new(I18n.t("crm_ui.opportunities.figures"), figures)])
      end

      # Saisie lue du formulaire, ou erreurs de lecture (montant, date).
      def read_input(form : Form) : Api::OpportunityInput?
        amount = field("amount").empty? ? BigDecimal.new(0) : decimal_field("amount")
        probability = field("probability").empty? ? nil : int_field("probability")
        close_on = field("expected_close_on").empty? ? nil : date_field("expected_close_on")
        form.add_error("amount", I18n.t("ui.forms.invalid_number")) if amount.nil?
        form.add_error("probability", I18n.t("ui.forms.invalid_integer")) if probability.nil? && !field("probability").empty?
        form.add_error("expected_close_on", I18n.t("ui.forms.invalid_date")) if close_on.nil? && !field("expected_close_on").empty?
        return if form.invalid || amount.nil?
        Api::OpportunityInput.new(title: field("title"), organization_id: id_field("organization_id") || 0_i64,
          contact_id: id_field("contact_id"), amount: amount, probability: probability, expected_close_on: close_on,
          owner_id: id_field("owner_id"), stage_id: id_field("stage_id"), source_id: id_field("source_id"))
      end
    end

    # `/ext/CRM/opportunities` : liste filtrable (texte, étape, statut,
    # responsable, « sans suite prévue »), triable, exportable en CSV.
    class OpportunitiesHandler < OpportunityScreen
      def get
        status = Api::OPPORTUNITY_STATUSES.includes?(query("status")) ? query("status") : (query("status") == "all" ? nil : "open")
        opportunity_query = Api::OpportunityQuery.new(stage_id: query("stage").to_i64?, status: status,
          owner_id: query("owner").to_i64?, no_next_step: query("next") == "1", limit: Api::MAX_LIMIT)
        views = Api.opportunities(actor, opportunity_query)
        params = {"q" => query("q"), "stage" => query("stage"), "status" => query("status"), "owner" => query("owner"),
                  "next" => query("next")}.reject { |_, value| value.empty? }
        actions = [link_action("crm_ui.pipeline.title", Ui.url("pipeline"), "", "layout-dashboard")]
        actions << link_action("crm_ui.opportunities.new", Ui.url("opportunity_new"), "primary", "plus") if can_write?
        list_page(I18n.t("crm.menu.crm_opportunities"), table(views, params), crumbs, "crm_ui.opportunities.csv_name", actions,
          filters: filters, intro: I18n.t("crm_ui.opportunities.intro"))
      end

      private def filters : Form
        stages = [option("", I18n.t("crm_ui.opportunities.all_stages"))] +
                 Api.stages(actor).map { |stage| option(stage.id.to_s, stage.label) }
        statuses = [option("", I18n.t("crm.opportunity_statuses.open")), option("won", I18n.t("crm.opportunity_statuses.won")),
                    option("lost", I18n.t("crm.opportunity_statuses.lost")), option("all", I18n.t("crm_ui.opportunities.all_statuses"))]
        Form.new([Form::Group.new(nil, [
          Form::Field.new("q", I18n.t("ui.table.search"), value: query("q"), placeholder: I18n.t("crm_ui.opportunities.search")),
          Form::Field.new("status", I18n.t("crm_ui.opportunities.status"), "select", query("status"), options: statuses),
          Form::Field.new("stage", I18n.t("crm_ui.opportunities.stage"), "select", query("stage"), options: stages),
          Form::Field.new("owner", I18n.t("crm_ui.opportunities.owner"), "select", query("owner"),
            options: [option("", I18n.t("crm_ui.opportunities.all_owners"))] + owner_options(blank: false)),
          Form::Field.new("next", I18n.t("crm_ui.opportunities.no_next_step"), "checkbox", query("next")),
        ])])
      end

      private def table(views : Array(Api::OpportunityView), params : Hash(String, String)) : Table
        columns = [
          Table::Column.new("title", I18n.t("crm_ui.opportunities.title_field")),
          Table::Column.new("organization", I18n.t("crm_ui.opportunities.organization")),
          Table::Column.new("stage", I18n.t("crm_ui.opportunities.stage")),
          Table::Column.new("amount", I18n.t("crm_ui.opportunities.amount"), "amount"),
          Table::Column.new("weighted", I18n.t("crm_ui.opportunities.weighted"), "amount", secondary: true),
          Table::Column.new("close_on", I18n.t("crm_ui.opportunities.close_on"), "mono", secondary: true),
          Table::Column.new("owner", I18n.t("crm_ui.opportunities.owner"), secondary: true),
          Table::Column.new("next", I18n.t("crm_ui.opportunities.next_step"), secondary: true),
        ]
        rows = views.map do |view|
          next_step = if view.no_next_step?
                        I18n.t("crm_ui.opportunities.no_next_step")
                      else
                        view.next_activity_on.try { |date| fmt.date(date) } || ""
                      end
          Table::Row.new([
            Table::Cell.new(view.title, Ui.url("opportunity", id: view.id)),
            Table::Cell.new(view.organization_name, Ui.url("organization", id: view.organization_id)),
            Table::Cell.new(view.stage.label, sort: view.stage.position.to_s.rjust(5, '0')),
            Table::Cell.new(fmt.amount(view.amount), sort: view.amount, csv: fmt.csv_amount(view.amount)),
            Table::Cell.new(fmt.amount(view.weighted_amount), sort: view.weighted_amount, csv: fmt.csv_amount(view.weighted_amount)),
            Table::Cell.new(view.expected_close_on.try { |date| fmt.date(date) } || "", sort: date_key(view.expected_close_on)),
            Table::Cell.new(view.owner_id.try { |id| owners[id]? } || ""),
            Table::Cell.new(next_step, sort: date_key(view.next_activity_on)),
          ], view.no_next_step? ? "crm-no-next" : "")
        end
        Table.new(I18n.t("crm.menu.crm_opportunities"), columns, rows, Ui.url("opportunities"), params,
          I18n.t("crm_ui.opportunities.none"), "crm-opportunities")
      end
    end

    # `/ext/CRM/opportunities/new` : nouvelle opportunité.
    class OpportunityNewHandler < OpportunityScreen
      def get
        show(opportunity_form(values_of(nil), creating: true))
      end

      def post
        form = opportunity_form(submitted, creating: true)
        if input = read_input(form)
          result = Api.create_opportunity(actor, input)
          if view = result.value?
            flash["success"] = I18n.t("crm_ui.flash.opportunity_created")
            return go(Ui.url("opportunity", id: view.id))
          end
          form.add_errors(result.errors, fmt)
        end
        show(form)
      end

      private def show(form : Form) : Marten::HTTP::Response
        title = I18n.t("crm_ui.opportunities.new")
        form_page(title, opportunity_crumbs(title), form, Ui.url("opportunity_new"), I18n.t("ui.forms.create"),
          Ui.url("opportunities"))
      end
    end

    # `/ext/CRM/opportunities/<id>/edit` : modification (l'étape se change
    # par le pipeline ou « Changer d'étape »).
    class OpportunityEditHandler < OpportunityScreen
      def get
        view = Api.opportunity(actor, id_param)
        show(view, opportunity_form(values_of(view), creating: false))
      end

      def post
        view = Api.opportunity(actor, id_param)
        form = opportunity_form(submitted, creating: false)
        if input = read_input(form)
          result = Api.update_opportunity(actor, view.id, input)
          if result.success?
            flash["success"] = I18n.t("crm_ui.flash.saved")
            return go(Ui.url("opportunity", id: view.id))
          end
          form.add_errors(result.errors, fmt)
        end
        show(view, form)
      end

      private def show(view : Api::OpportunityView, form : Form) : Marten::HTTP::Response
        url = Ui.url("opportunity", id: view.id)
        form_page(I18n.t("crm_ui.opportunities.edit"), opportunity_crumbs(view.title, url), form,
          Ui.url("opportunity_edit", id: view.id), I18n.t("ui.forms.save"), url)
      end
    end

    # `/ext/CRM/opportunities/<id>` : consultation — rubriques, devis et
    # factures, activités, historique des étapes ; actions.
    class OpportunityHandler < OpportunityScreen
      def get
        view = Api.opportunity(actor, id_param)
        sections = [summary(view), documents(view), activities(view), history(view)]
        detail_page(view.title, opportunity_crumbs(view.title), sections, actions(view), I18n.t(view.status_key),
          view.no_next_step? ? I18n.t("crm_ui.opportunities.no_next_step_help") : nil)
      end

      private def actions(view : Api::OpportunityView) : Array(Screen::Action)
        list = [] of Screen::Action
        return list unless can_write?
        if view.open? && can?(Partiduo::Api::Invoicing::WRITE) && module_active?("INVOICING")
          list << post_action("crm_ui.opportunities.create_quote", Ui.url("opportunity_quote", id: view.id),
            view.organization_customer ? nil : "crm_ui.opportunities.create_quote_confirm", "primary", "file-text")
        end
        list << link_action("crm_ui.opportunities.move", Ui.url("opportunity_move", id: view.id), "", "send")
        list << link_action("crm_ui.activities.new", "#{Ui.url("activity_new")}?opportunity=#{view.id}", "", "calendar")
        list << link_action("ui.forms.edit", Ui.url("opportunity_edit", id: view.id), "", "notebook-pen")
        list
      end

      private def summary(view : Api::OpportunityView) : Screen::Section
        items = [
          Screen::Item.new(I18n.t("crm_ui.opportunities.organization"), view.organization_name, Ui.url("organization", id: view.organization_id)),
          Screen::Item.new(I18n.t("crm_ui.opportunities.contact"), view.contact_name || "", view.contact_id.try { |id| Ui.url("contact", id: id) }),
          Screen::Item.new(I18n.t("crm_ui.opportunities.stage"), view.stage.label),
          Screen::Item.new(I18n.t("crm_ui.opportunities.amount"), fmt.amount(view.amount), mono: true),
          Screen::Item.new(I18n.t("crm_ui.opportunities.probability"), "#{view.probability} %", mono: true),
          Screen::Item.new(I18n.t("crm_ui.opportunities.weighted"), fmt.amount(view.weighted_amount), mono: true),
          Screen::Item.new(I18n.t("crm_ui.opportunities.close_on"), view.expected_close_on.try { |date| fmt.date(date) } || ""),
          Screen::Item.new(I18n.t("crm_ui.opportunities.owner"), view.owner_id.try { |id| owners[id]? } || ""),
          Screen::Item.new(I18n.t("crm_ui.opportunities.source"), source_label(view.source_id)),
          Screen::Item.new(I18n.t("crm_ui.opportunities.next_step"), next_step(view)),
          Screen::Item.new(I18n.t("crm_ui.opportunities.closed_at"), view.closed_at.try { |time| fmt.date(time) } || ""),
        ]
        if reason = view.loss_reason_id
          items << Screen::Item.new(I18n.t("crm_ui.opportunities.loss_reason"),
            Api.loss_reasons(actor).find(&.id.==(reason)).try(&.label) || "")
          items << Screen::Item.new(I18n.t("crm_ui.opportunities.loss_note"), view.loss_note)
        end
        Screen::Section.new(I18n.t("crm_ui.opportunities.summary"), items)
      end

      private def next_step(view : Api::OpportunityView) : String
        return I18n.t("crm_ui.opportunities.no_next_step") if view.no_next_step?
        view.next_activity_on.try { |date| fmt.date(date) } || ""
      end

      private def source_label(id : Int64?) : String
        return "" if id.nil?
        Api.sources(actor).find(&.id.==(id)).try(&.label) || ""
      end

      private def documents(view : Api::OpportunityView) : Screen::Section
        columns = [
          Table::Column.new("kind", I18n.t("crm_ui.documents.kind")),
          Table::Column.new("number", I18n.t("crm_ui.documents.number"), "mono"),
          Table::Column.new("status", I18n.t("crm_ui.documents.status")),
          Table::Column.new("date", I18n.t("crm_ui.documents.date"), "mono", secondary: true),
          Table::Column.new("total", I18n.t("crm_ui.documents.total_net"), "amount"),
        ]
        rows = Api.documents(actor, view.id).map do |document|
          url = document.readable ? Ui.route("invoicing:document", id: document.document_id) : nil
          Table::Row.new([
            Table::Cell.new(I18n.t(document.kind_key)),
            Table::Cell.new(document.number || (document.readable ? I18n.t("crm_ui.documents.draft") : "##{document.document_id}"), url),
            Table::Cell.new(document.status_key.try { |key| I18n.t(key) } || ""),
            Table::Cell.new(document.issue_date.try { |date| fmt.date(date) } || "", sort: date_key(document.issue_date)),
            Table::Cell.new(document.total_net.try { |amount| fmt.amount(amount) } || "", sort: document.total_net || BigDecimal.new(0)),
          ])
        end
        table = Table.new(I18n.t("crm_ui.documents.title"), columns, rows, Ui.url("opportunity", id: view.id),
          empty_message: I18n.t("crm_ui.documents.none"), id: "crm-documents")
        table.exportable = false
        Screen::Section.new(I18n.t("crm_ui.documents.title"), table: table)
      end

      private def activities(view : Api::OpportunityView) : Screen::Section
        Screen::Section.new(I18n.t("crm_ui.activities.title"),
          table: Ui.activity_table(self, Api.activities(actor, Api::ActivityQuery.new(opportunity_id: view.id)),
            Ui.url("opportunity", id: view.id), "crm-opportunity-activities"))
      end

      private def history(view : Api::OpportunityView) : Screen::Section
        columns = [
          Table::Column.new("at", I18n.t("crm_ui.history.at"), "mono"),
          Table::Column.new("from", I18n.t("crm_ui.history.from")),
          Table::Column.new("to", I18n.t("crm_ui.history.to")),
          Table::Column.new("by", I18n.t("crm_ui.history.by"), secondary: true),
          Table::Column.new("cause", I18n.t("crm_ui.history.cause"), secondary: true),
        ]
        rows = Api.stage_history(actor, view.id).reverse.map do |change|
          Table::Row.new([
            Table::Cell.new(fmt.datetime(change.created_at), sort: change.created_at.to_rfc3339),
            Table::Cell.new(change.from_stage.try(&.label) || "—"),
            Table::Cell.new(change.to_stage.label),
            Table::Cell.new(change.user_id.try { |id| owners[id]? } || "—"),
            Table::Cell.new(change.cause_key.try { |key| I18n.t(key) } || ""),
          ])
        end
        table = Table.new(I18n.t("crm_ui.history.title"), columns, rows, Ui.url("opportunity", id: view.id), id: "crm-history")
        table.exportable = false
        Screen::Section.new(I18n.t("crm_ui.history.title"), table: table)
      end
    end

    # `/ext/CRM/opportunities/<id>/quote` : « Créer un devis » (ADR-009 D5),
    # puis l'édition du devis dans la Facturation.
    class OpportunityQuoteHandler < Handler
      def get
        go(Ui.url("opportunity", id: id_param))
      end

      def post
        result = Api.create_quote(actor, id_param)
        if quote = result.value?
          flash["success"] = I18n.t("crm_ui.flash.quote_created")
          return go(Ui.route("invoicing:document_edit", id: quote.id))
        end
        flash["danger"] = result.errors.map { |error| fmt.message(error) }.join(" ")
        go(Ui.url("opportunity", id: id_param))
      end
    end
  end
end
