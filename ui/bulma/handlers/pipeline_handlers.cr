# SPDX-License-Identifier: AGPL-3.0-or-later

module Crm
  module Ui
    # Pipeline en colonnes par étape (ADR-009 D3), commun à l'écran et au
    # déplacement d'une carte : chaque carte porte ses boutons « ← » et
    # « → » (étape précédente, suivante), qui marchent sans JavaScript, au
    # clavier et au toucher ; `crm/js/pipeline.js` ajoute le glisser-déposer
    # à la souris et les raccourcis Maj+← / Maj+→ sur la carte qui a le focus,
    # et HTMX ne remplace que le tableau (`#crm-board`), en annonçant le
    # déplacement dans la région d'état.
    module PipelineBoard
      def pipeline_page(owner : Int64?, announce : String? = nil) : Marten::HTTP::Response
        view = Api.pipeline(actor, owner_id: owner)
        stages = view.columns.map(&.stage)
        columns = view.columns.map { |column| column_row(column, stages) }
        actions = [link_action("crm.menu.crm_opportunities", Ui.url("opportunities"), "", "book-open")]
        actions << link_action("crm_ui.opportunities.new", Ui.url("opportunity_new"), "primary", "plus") if can_write?
        page("crm/pipeline.html", {
          "title"    => I18n.t("crm_ui.pipeline.title"),
          "crumbs"   => crumbs({I18n.t("crm_ui.pipeline.title"), nil}),
          "actions"  => actions,
          "columns"  => columns,
          "weighted" => fmt.amount(view.weighted_amount),
          "announce" => announce,
          "owner"    => owner.try(&.to_s) || "",
          "owners"   => [Ui.row({"value" => "", "label" => I18n.t("crm_ui.opportunities.all_owners"), "selected" => Ui.flag(owner.nil?)})] +
                      owners.to_a.sort_by!(&.[1]).map { |(id, name)| Ui.row({"value" => id.to_s, "label" => name, "selected" => Ui.flag(owner == id)}) },
          "can_write" => Ui.flag(can_write?),
        })
      end

      # Colonne : étape, total, cartes ; chaque carte connaît les étapes
      # voisines (« Perdue » revient à la dernière étape de travail ; on n'y
      # va que par « Autre étape… », qui demande le motif).
      private def column_row(column : Api::ColumnView, stages : Array(Api::StageView)) : Row
        stage = column.stage
        cards = column.opportunities.map do |opportunity|
          previous, following = neighbours(stage, stages)
          card = Present.opportunity(opportunity, fmt, owners)
          card.values.merge!({
            "move_url"   => Ui.url("opportunity_move", id: opportunity.id),
            "prev_id"    => previous.try(&.id.to_s),
            "prev_label" => previous.try(&.label),
            "next_id"    => following.try(&.id.to_s),
            "next_label" => following.try(&.label),
          })
          card
        end
        Ui.row({
          "id"          => stage.id.to_s,
          "label"       => stage.label,
          "kind"        => stage.kind,
          "count"       => column.opportunities.size.to_s,
          "count_label" => I18n.t("crm_ui.pipeline.count", count: column.opportunities.size),
          "amount"      => fmt.amount(column.amount),
          "weighted"    => fmt.amount(column.weighted_amount),
          "closing"     => Ui.flag(stage.closing?),
        }, {"cards" => cards})
      end

      private def neighbours(stage : Api::StageView, stages : Array(Api::StageView)) : {Api::StageView?, Api::StageView?}
        working = stages.select(&.open?)
        won = stages.find(&.won?)
        case stage.kind
        when "open"
          index = working.index(&.id.==(stage.id)) || 0
          {index > 0 ? working[index - 1] : nil, working[index + 1]? || won}
        else
          {working.last?, nil}
        end
      end
    end

    # `/ext/CRM/pipeline` : colonnes par étape, filtre par responsable.
    class PipelineHandler < Handler
      include PipelineBoard

      def get
        pipeline_page(query("owner").to_i64?)
      end
    end

    # `/ext/CRM/opportunities/<id>/move` : changement d'étape. GET : écran
    # « Changer d'étape » (toute étape active, motif pour « Perdue ») ;
    # POST : depuis cet écran, ou depuis une carte du pipeline (`from` =
    # `pipeline` : HTMX reçoit le tableau mis à jour).
    class OpportunityMoveHandler < Handler
      include PipelineBoard

      def get
        view = Api.opportunity(actor, id_param)
        values = {"stage_id" => query("stage").presence || view.stage.id.to_s, "loss_reason_id" => "", "loss_note" => ""}
        show(view, move_form(values))
      end

      def post
        view = Api.opportunity(actor, id_param)
        stage_id = id_field("stage_id") || 0_i64
        input = Api::MoveInput.new(stage_id, id_field("loss_reason_id"), field("loss_note", strip: false))
        return from_pipeline(view, input) if field("from") == "pipeline"

        result = Api.move_opportunity(actor, view.id, input)
        if result.success?
          flash["success"] = I18n.t("crm_ui.flash.moved")
          return go(Ui.url("opportunity", id: view.id))
        end
        form = move_form({"stage_id" => field("stage_id"), "loss_reason_id" => field("loss_reason_id"),
                          "loss_note" => field("loss_note", strip: false)})
        show(view, form.add_errors(result.errors, fmt))
      end

      private def from_pipeline(view : Api::OpportunityView, input : Api::MoveInput) : Marten::HTTP::Response
        owner = field("owner").to_i64?
        target = Api.stages(actor).find(&.id.==(input.stage_id))
        # « Perdue » demande un motif : l'écran « Changer d'étape » le recueille.
        if target && target.lost? && input.loss_reason_id.nil?
          return go("#{Ui.url("opportunity_move", id: view.id)}?stage=#{target.id}")
        end
        result = Api.move_opportunity(actor, view.id, input)
        announce = if moved = result.value?
                     I18n.t("crm_ui.pipeline.moved", title: moved.title, stage: moved.stage.label)
                   else
                     result.errors.map { |error| fmt.message(error) }.join(" ")
                   end
        return pipeline_page(owner, announce) if htmx?
        flash[result.success? ? "success" : "danger"] = announce
        go(owner ? "#{Ui.url("pipeline")}?owner=#{owner}" : Ui.url("pipeline"))
      end

      private def move_form(values : Hash(String, String)) : Form
        stages = Api.stages(actor, active_only: true).map { |stage| option(stage.id.to_s, stage.label) }
        reasons = [blank_option] + Api.loss_reasons(actor, active_only: true).map { |reason| option(reason.id.to_s, reason.label) }
        Form.new([Form::Group.new(nil, [
          Form::Field.new("stage_id", I18n.t("crm_ui.opportunities.stage"), "select", values["stage_id"], options: stages, required: true),
          Form::Field.new("loss_reason_id", I18n.t("crm_ui.opportunities.loss_reason"), "select", values["loss_reason_id"],
            options: reasons, help: I18n.t("crm_ui.opportunities.loss_reason_help")),
          Form::Field.new("loss_note", I18n.t("crm_ui.opportunities.loss_note"), "textarea", values["loss_note"], wide: true,
            maxlength: 2000),
        ])])
      end

      private def show(view : Api::OpportunityView, form : Form) : Marten::HTTP::Response
        url = Ui.url("opportunity", id: view.id)
        title = I18n.t("crm_ui.opportunities.move")
        form_page(title, crumbs({I18n.t("crm.menu.crm_opportunities"), Ui.url("opportunities")}, {view.title, url}, {title, nil}),
          form, Ui.url("opportunity_move", id: view.id), I18n.t("crm_ui.opportunities.move_submit"), url,
          intro: I18n.t("crm_ui.opportunities.move_intro", stage: view.stage.label))
      end
    end
  end
end
