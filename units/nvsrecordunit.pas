unit NVSRecordUnit;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, EmerAPIMain, emerapitypes,UTXOunit, fpjson, jsonparser, EmerAPIBlockchainUnit, EmerAPITransactionUnit,{ttxounit,} BaseTXUnit;

type
//Events:
//update
//error
//sent

tNVSRecord= class ({tEmerApiNotified}tBaseTXO) //tEmerApiNotified? tObject?
  private
    fNVSName:ansistring; //Overwritten. may be differ from fScriptToSign
    fNVSValue:ansistring; //Overwritten. may be differ from fScriptToSign
    fDays:qword; //Overwritten. may be differ from fScriptToSign. It is data from the LAST UTXO script
        fDaysLeft:int64; //calculated by name_show. -1 if don't know
    fOwnerAddress:ansistring; //Overwritten. may be differ from fScriptToSign
    fEmerAPI:tEmerAPI;
    //procedure SetDays(v:dword);
    fOnSavedToBlockchain:tNotifyEvent; //+sent
    fOnReadFromBlockchain:tNotifyEvent;
    fOnError:tNotifyEvent;
    freadTXAfterLoad:boolean;
  public
    LastError:string;

    DaysAdd:qword; //days to add
    newValue:ansistring;
    newOwner:ansistring;

    property readTXAfterLoad:boolean read freadTXAfterLoad write freadTXAfterLoad;

    property NVSName:ansistring read fNVSName;
    property NVSValue:ansistring read fNVSValue write fNVSValue;
    property ownerAddress:ansistring read fOwnerAddress write fOwnerAddress;
    property Days:qword read fDays write fDays;

    property OnSavedToBlockchain:tNotifyEvent read fOnSavedToBlockchain write fOnSavedToBlockchain;
    property OnReadFromBlockchain:tNotifyEvent  read fOnReadFromBlockchain  write fOnReadFromBlockchain;
    property OnError:tNotifyEvent  read fOnError write fOnError;

    function DaysLeft:int64;

    function isLoaded:boolean;
    function isUpdateNeeded:boolean;
    procedure readInputTxInfo(); //reads nOut, script and others
    procedure SaveToBlockchain();
    procedure readFromBlockchain();

    procedure sendingErrorHandler(Sender: TObject);
    procedure sentHandler(Sender: TObject);


    procedure loadfromTXO(const txo:tBaseTXO);
    constructor create(emerAPI:tEmerAPI); overload;
    constructor create(emerAPI:tEmerAPI; mNVSName:ansistring; readAfterCreate:boolean=false; myReadTXAfterCreate:boolean=false); overload;
    constructor create(emerAPI:tEmerAPI; const utxo:tUTXO; readAfterCreate:boolean=false; myReadTXAfterCreate:boolean=false); overload;
    constructor create(emerAPI:tEmerAPI; mNVSName,mNVSValue:ansistring; mDays:qword; mOwnerAddress:ansistring;readAfterCreate:boolean=false); overload;
    constructor createByTXO(emerAPI:tEmerAPI; const txo:tEmerTransactionOut; readAfterCreate:boolean=false);


    procedure fillDataByUTXO(utxo:tUTXO);

    procedure AsyncRequestDone(sender:TEmerAPIBlockchainThread;result:tJsonData);//update_: write fDeepness, fSpending, ftxid, fn, fScriptToSign, fvalue, fHeight  load_:
end;

implementation

uses EmerTX, crypto, math, mainUnit, CryptoLib4PascalConnectorUnit;
{tNVSRecord}


function tNVSRecord.isLoaded:boolean;
begin
  //we have all information
  //we have:
  result:=
    (ftxid<>'')
    and
    (nOut>=0)
    and
    (fDaysLeft>=0);
end;

function tNVSRecord.isUpdateNeeded:boolean;
begin
  //information in fScriptToSign is matched to fNVSName fNVSValue fDays fOwnerAddress
end;

procedure tNVSRecord.sendingErrorHandler(Sender: TObject);
begin
 if Sender is tEmerTransaction
   then LastError:='Error: Name TX sending error: '+tEmerTransaction(sender).lastError
   else LastError:='Error: Name TX sending error';

 if assigned(fOnError) then fOnError(self);
 callNotify('error');
end;

procedure tNVSRecord.sentHandler(Sender: TObject);
begin
  //ShowMessageSafe('Successfully sent');
  if assigned(fOnSavedToBlockchain) then fOnSavedToBlockchain(self);
  callNotify('sent');
end;

procedure tNVSRecord.readInputTxInfo();
begin
  femerAPI.EmerAPIConnetor.sendWalletQueryAsync('getrawtransaction',
    getJSON('{txid:"'+bufToHex(ftxid)+'"}')
   ,@AsyncRequestDone,'loadtx:'+trim(fNVSName));
end;

procedure tNVSRecord.SaveToBlockchain();
var tx:tEmerTransaction;
    nAddress,nName,nValue:ansistring;
    nDays:qword;
begin


  if length(newValue)>20480 then exit;

  if (DaysAdd=0) and ((newValue='') or (newValue=fNVSValue)) and ((newOwner='') or (newOwner=fOwnerAddress)) then exit;

  //Если данные не заполнены
  if (nOut<0) or (fScript='') then begin
     femerAPI.EmerAPIConnetor.sendWalletQueryAsync('getrawtransaction',
       getJSON('{txid:"'+bufToHex(ftxid)+'"}')
       ,@AsyncRequestDone,'loadtxandsave:'+trim(fNVSName));
     exit;
  end;

  //now we can save changes: newOwner, DaysAdd and newValue

  nName:=NVSName;

  nAddress:=mainForm.globals.AddressSig+ownerAddress;
  if newOwner<>'' then
    nAddress:=mainForm.globals.AddressSig+newOwner;

  nValue:=NVSValue;
  if newValue<>'' then
    nValue:=newValue;

  nDays:=max(0,DaysAdd);

  //create and send a new TX

  tx:=tEmerTransaction.create(fEmerAPI,true);
  try

    tx.addInput(txid,nOut,value,Script);
    tx.addOutput(tx.createNameScript(nAddress,nName,nValue,nDays,false),fEmerAPI.blockChain.MIN_TX_FEE);

    if tx.makeComplete then begin
      if tx.signAllInputs(MainForm.getPrivKey(nAddress)) then begin
        tx.sendToBlockchain(EmerAPINotification(@SentHandler,'sent'));
        tx.addNotify(EmerAPINotification(@SendingErrorHandler,'error'));
      end else begin
        LastError:='Error: Can''t sign all transaction inputs using current key: '+tx.LastError;
        if assigned(fOnError) then fOnError(self);
        callNotify('error');
      end;
    end else begin
      LastError:='Error: Can''t create transaction: '+tx.LastError;
      if assigned(fOnError) then fOnError(self);
      callNotify('error');
    end;
  except
    on e:exception do begin
      LastError:='Error: can''t send TX: '+e.Message;
      if assigned(fOnError) then fOnError(self);
      callNotify('error');
      tx.Free;
    end;
  end;
end;

procedure tNVSRecord.readFromBlockchain();
var utxo:tUTXO;
begin
  //try to read from our UTXOList first
  //call only by Name!
  utxo:=femerAPI.UTXOList.findName(fNVSName);
  if utxo<>nil then //begin
    fillDataByUTXO(utxo);
    //femerAPI.EmerAPIConnetor.sendWalletQueryAsync('name_show',getJSON('{name:"'+fNVSName+'"}'),@AsyncRequestDone,'checkname:'+trim(fNVSName));
    //exit;
  //end;

  //request from BC
  femerAPI.EmerAPIConnetor.sendWalletQueryAsync('name_show',getJSON('{name:"'+fNVSName+'"}'),@AsyncRequestDone,'checkname:'+trim(fNVSName));
end;


constructor tNVSRecord.create(emerAPI:tEmerAPI); overload;
begin
  create(emerAPI,nil,false);
end;

constructor tNVSRecord.create(emerAPI:tEmerAPI; mNVSName,mNVSValue:ansistring; mDays:qword; mOwnerAddress:ansistring;readAfterCreate:boolean=false);
begin
  create(emerAPI,nil,false);
  fNVSName:=mNVSName;
  fNVSValue:=mNVSValue;
  fDays:=mDays;
  fOwnerAddress:=mOwnerAddress;
  if readAfterCreate then readFromBlockchain;
end;

constructor tNVSRecord.create(emerAPI:tEmerAPI; mNVSName:ansistring; readAfterCreate:boolean=false; myReadTXAfterCreate:boolean=false);
begin
  create(emerAPI,nil,false);
  fNVSName:=mNVSName;
  if readAfterCreate then readFromBlockchain;
  freadTXAfterLoad:=myReadTXAfterCreate;
end;

constructor tNVSRecord.create(emerAPI:tEmerAPI;const utxo:tUTXO; readAfterCreate:boolean=false; myreadTXAfterCreate:boolean=false);
begin
  //if utxo=nil then raise exception.Create('tNVSRecord.create: UTXO is nil');
  if utxo<>nil then
    if not utxo.isName then raise exception.Create('tNVSRecord.create: UTXO is not an NVS record');
  //fnOut:=-1;

  inherited create;

  fEmerAPI:=EmerAPI;
  fillDataByUTXO(utxo);
  freadTXAfterLoad:=myreadTXAfterCreate;
  if freadTXAfterLoad then
    readInputTxInfo;

end;


procedure tNVSRecord.loadfromTXO(const txo:tBaseTXO);
var nameScript:tNameScript;
begin
  nameScript:=nameScriptDecode(txo.script);

  ftxid:=txo.owner.getTXID;
  fnOut:=txo.nOut;
  fscript:=txo.script;
  fvalue:=txo.value;

  //fOwner:=txo.owner;
  fOwner:=nil;

  //loadFromScriptToSign(fScriptToSign)

  fNVSName:=nameScript.Name;
  fNVSValue:=nameScript.Value;
  fDays:=nameScript.Days;
  fOwnerAddress:=nameScript.Owner;

end;

constructor tNVSRecord.createByTXO(emerAPI:tEmerAPI; const txo:tEmerTransactionOut; readAfterCreate:boolean=false);
begin
  if txo=nil then raise exception.Create('tNVSRecord.create(emerAPI:tEmerAPI; const txo=nil');

  inherited create;
  //fnOut:=-1;

  fEmerAPI:=EmerAPI;
  fillDataByUTXO(nil);

  fHeight:=0; //not in BC or unknown
  DaysAdd:=0;
  newValue:='';
  newOwner:='';
  fDaysLeft:=-1;

  loadfromTXO(txo);

  if readAfterCreate then readFromBlockchain;
end;

procedure tNVSRecord.fillDataByUTXO(utxo:tUTXO);
var nameScript:tNameScript;
begin
  //write fDeepness, fSpending, ftxid, fn, fScriptToSign, fvalue, fHeight
  //if utxo=nil then raise exception.Create('tNVSRecord.fillDataByUTXO: UTXO is nil');
  //if not utxo.isName then raise exception.Create('tNVSRecord.create: UTXO is not an NVS record');

  if utxo=nil then begin
    ftxid:='';
    fnOut:=-1;
    fScript:='';
    fvalue:=0;
    fHeight:=0;

    fOwner:=nil;

    fNVSName:='';
    fNVSValue:='';
    fDays:=0;
    fOwnerAddress:='';

    DaysAdd:=0;
    newValue:='';
    newOwner:='';
    fDaysLeft:=-1;

  end else begin
    ftxid:=utxo.txid;
    fnOut:=utxo.nOut;
    fScript:=utxo.Script;
    fvalue:=utxo.value;
    fHeight:=utxo.Height;

    if fOwner<>utxo.ownerTX then fOwner:=nil; //we are breaking link with the owner, but will use fnOut
    //loadFromScriptToSign(fScriptToSign)
    nameScript:=nameScriptDecode(fScript);

    fNVSName:=nameScript.Name;
    fNVSValue:=nameScript.Value;
    fDays:=nameScript.Days;
    fOwnerAddress:=nameScript.Owner;

    DaysAdd:=0;
    newValue:='';
    newOwner:='';
    fDaysLeft:=-1; //unknown

  end;
end;

//scantxoutset "start"  '[{"address":"miuA1RdPgyzrBLyTfe8AWzZRwJux1Zptst"}]'

function tNVSRecord.DaysLeft:int64;
begin
{  if fHeight=0 //have read from BC. days is LEFT days
    then result:=fDaysLeft
    else result:=max(0,trunc(Days -  (fEmerAPI.blockChain.Height-fHeight)/175 ));
    }
  result:=-1;
  if fDaysLeft>=0
    then result:=fDaysLeft
    else if (fHeight>0) and (fScript<>'') and (fScript[1]=#$51) //name_add
       then result:=max(0,trunc(Days -  (fEmerAPI.blockChain.Height-fHeight)/175 ));
end;


procedure tNVSRecord.AsyncRequestDone(sender:TEmerAPIBlockchainThread;result:tJsonData);//update_: write fDeepness, fSpending, ftxid, fn, fScriptToSign, fvalue, fHeight  load_:
var e:tJsonData;
    //s:string;
    //val,x:double;
    //nc,i,n:integer;
    //st:ansistring;
    //vR,vY,vS:double;
    //nameScript:tNameScript;
    //amount:integer;
    tx:tbaseTX;
    txo:tBaseTXO;

begin
  if result=nil then begin
    //error
    LastError:=sender.lastError;
    if assigned(fOnError) then fOnError(self);
    callNotify('error');
    exit;
  end;
  //set fScriptToSign :
  //1. read successeful
  //2. write successeful


  if (sender.id=('loadtxandsave:'+trim(fNVSName))) or (sender.id=('loadtx:'+trim(fNVSName))) then begin
    //fnOut , fScript

    if result<>nil then begin
     e:=result.FindPath('result');
     if (e<>nil) and (not e.IsNull) then begin
       //we have received a raw tx.
       //let's find the name
       if ftxid<>reverse(dosha256(dosha256(hexToBuf(e.asString)))) then begin
         LastError:='Error: loadtxandsave: TX loaded is not the same with requested: '+bufToHex(ftxid)+'<>'+bufToHex(reverse(dosha256(dosha256(hexToBuf(e.asString)))));
         if assigned(fOnError) then fOnError(self);
         callNotify('error');
         exit;
       end;

       tx:=tbaseTX.create(hexToBuf(e.asString));
       try
         txo:=tx.findNameOut(fNVSName);
         if txo=nil then begin
           LastError:='Error: loadtxandsave: Name "'+fNVSName+'" is not found in the hx: '+bufToHex(ftxid);
           if assigned(fOnError) then fOnError(self);
           callNotify('error');
           exit;
         end;


         loadfromTXO(txo);

         if (nOut<0) or (fScript='') then begin
           LastError:='Error: loadtxandsave: Name "'+fNVSName+'" has wrong data in the hx: '+bufToHex(ftxid);
           if assigned(fOnError) then fOnError(self);
           callNotify('error');
           exit;
         end;

         if (sender.id=('loadtxandsave:'+trim(fNVSName))) then
           SaveToBlockchain()
         else begin
           if assigned(fOnReadFromBlockchain) then fOnReadFromBlockchain(self);
           callNotify('update');
         end;
       finally
         tx.free;
       end;


     end else begin
       LastError:='Error: loadtxandsave: result has no TX data: '+result.AsJSON;
       if assigned(fOnError) then fOnError(self);
       callNotify('error');
     end;
    end else begin
       LastError:='Error: loadtxandsave: '+sender.lastError;
       if assigned(fOnError) then fOnError(self);
       callNotify('error');
    end;
  end;


  if (sender.id=('checkname:'+trim(fNVSName)))
//      or
//     (sender.id=('checknameandsave:'+trim(fNVSName)))
  then begin
   e:=result.FindPath('result');
   if e<>nil then
      if e.IsNull then begin
        LastError:='Name not found: '+trim(fNVSName);
        if assigned(fOnError) then fOnError(self);
        callNotify('error');
      end else
      try


        if ftxid<>'' then
          if ftxid<>hexToBuf(e.FindPath('txid').AsString) then begin
            //this is not my name, really
            fnOut:=-1;  //unknown
            fScript:='';  //unknown
            fvalue:=0;  //unknown
            fHeight:=0; //unknown
            fOwner:=nil;

            //clear changes
            DaysAdd:=0;
            newValue:='';
            newOwner:='';
           end;

        ftxid:=hexToBuf(e.FindPath('txid').AsString);

        fNVSName:=e.FindPath('name').AsString;
        fNVSValue:=e.FindPath('value').AsString;

        fDays:=0; //unknown
        fDaysLeft:=trunc({now() +} e.FindPath('expires_in').AsInt64/175); //LEFT

        if fDaysLeft<0 then fDaysLeft:=0;


        fOwnerAddress:=base58ToBufCheck(e.FindPath('address').AsString); delete(fOwnerAddress,1,1);
        //check signature? Да ну, в задницу! Сколько можно?

        //if we don't have nOut we have to request ftxid . else work is done

        if freadTXAfterLoad and (nOut<0) then
          readInputTxInfo
        else begin
          if assigned(fOnReadFromBlockchain) then fOnReadFromBlockchain(self);
          callNotify('update');
        end;
      except
        LastError:='Error: incorrect name data in: '+result.AsJSON;
        if assigned(fOnError) then fOnError(self);
        callNotify('error');
      end
   else begin
     LastError:='Error: can''t find result in: '+result.AsJSON;
     if assigned(fOnError) then fOnError(self);
     callNotify('error');
   end;
  end else begin
    //wrong name :-/
    //raise exception.Create('');
    LastError:='wrong name returned from blockchain';
    if assigned(fOnError) then fOnError(self);
    callNotify('error');
  end;
end;

end.

