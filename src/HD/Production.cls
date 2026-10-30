Class HD.Production Extends Ens.Production
{
XData ProductionDefinition
{
<Production Name="HD.Production" TestingEnabled="true" LogGeneralTraceEvents="true">
 <Item Name="FHIRFileIntake" ClassName="HD.FHIRFileService" PoolSize="1" Enabled="true" Foreground="false"><Setting Target="Adapter" Name="CallInterval">3</Setting></Item>
 <Item Name="FHIRIntake" ClassName="HD.Service" PoolSize="0" Enabled="true" Foreground="false"/>
 <Item Name="FHIRProcess" ClassName="HD.Process" PoolSize="1" Enabled="true" Foreground="false"/>
 <Item Name="FHIRRoute" ClassName="HD.FHIRRoute" PoolSize="1" Enabled="true" Foreground="false"/>
 <Item Name="AgentReview" ClassName="HD.AgentOperation" PoolSize="1" Enabled="true" Foreground="false"/>
 <Item Name="EmbeddedVector" ClassName="HD.EmbeddedVectorOperation" PoolSize="1" Enabled="true" Foreground="false"/>
 <Item Name="WorkflowDispatch" ClassName="HD.WorkflowDispatch" PoolSize="1" Enabled="true" Foreground="false"/>
 <Item Name="MedicalAuditReviewer" ClassName="EnsLib.Workflow.Operation" PoolSize="1" Enabled="true" Foreground="false"><Setting Target="Host" Name="AutoCreateRole">1</Setting></Item>
 <Item Name="AuditEvent" ClassName="HD.Audit" PoolSize="1" Enabled="true" Foreground="false"/>
</Production>
}
}
